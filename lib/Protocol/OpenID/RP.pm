package Protocol::OpenID::RP;
use Mouse;

use Async::Hooks;
use Protocol::Yadis;
use Protocol::OpenID::Nonce;
use Protocol::OpenID::Identifier;
use Protocol::OpenID::Signature;
use Protocol::OpenID::Association;
use Protocol::OpenID::Parameters;
use Protocol::OpenID::Discovery;
use Protocol::OpenID::Discovery::Yadis;
use Protocol::OpenID::Discovery::HTML;

has hooks => (
    isa     => 'Async::Hooks',
    default => sub { Async::Hooks->new },
    is      => 'ro',
    lazy    => 1,
    handles => [qw( hook call )],
);

has http_req_cb => (
    isa      => 'CodeRef',
    is       => 'rw',
    required => 1
);

has store_cb => (
    isa => 'CodeRef',
    is  => 'rw'
);

has find_cb => (
    isa     => 'CodeRef',
    is      => 'rw',
    default => sub { sub {} }
);

has remove_cb => (
    isa     => 'CodeRef',
    is      => 'rw',
    default => sub { sub {} }
);

has return_to => (
    isa      => 'Str',
    is       => 'rw'
);

has discovery => (
    isa     => 'Protocol::OpenID::Discovery',
    is      => 'rw',
    clearer => 'clear_discovery'
);

has association => (
    isa     => 'Protocol::OpenID::Association',
    is      => 'rw',
    clearer => 'clear_association',
    default => sub { Protocol::OpenID::Association->new }
);

has error => (
    isa => 'Str',
    is  => 'rw',
    clearer => 'clear_error'
);

# debugging
has debug => (
    isa     => 'Int',
    is      => 'rw',
    default => sub { $ENV{PROTOCOL_OPENID_DEBUG} || 0 }
);

has _associate_counter => (
    isa     => 'Int',
    is      => 'rw',
    default => 0
);

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    # Yadis discovery hook
    $self->hook(discover => \&Protocol::OpenID::Discovery::Yadis::hook);

    # HTML discovery hook
    $self->hook(discover => \&Protocol::OpenID::Discovery::HTML::hook);

    return $self;
}

sub authenticate {
    my $self = shift;
    my ($params, $cb) = @_;

    # Din't put 'required => 1' into attribute definition because:
    # - it is only required now
    # - one can create an object and use it in many places without a need to
    #   specify return_to on its creation
    die 'return_to is required' unless $self->return_to;

    # From User Agent
    if (my $openid_identifier = $params->{'openid_identifier'}) {

        # Normalization
        my $identifier = Protocol::OpenID::Identifier->new($openid_identifier);

        # Discovery hook chain
        $self->call(
            discover => [$self, $identifier] => sub {
                my ($ctl, $args, $is_done) = @_;

                my $discovery = $self->discovery;

                # Return if discovery was unsuccessful
                return $cb->($self, undef, 'error') unless $discovery;

                # Start association with OP
                $self->_associate(
                    $discovery->op_endpoint,
                    sub {
                        my ($self, $result) = @_;

                        # Store association
                        if ($result eq 'ok') {
                            warn 'Association ran fine, storing it'
                              if $self->debug;

                            my $assoc_handle = $self->association->assoc_handle;

                            return $self->store_cb->(
                                $assoc_handle => $self->association->to_hash,
                                sub { return $self->_redirect($cb); }
                            );
                        }

                        # Skip association
                        elsif ($result eq 'skip') {
                            warn 'Skipping association for various reasons'
                              if $self->debug;
                        }

                        # Give up on association, but don't fail, it is OPTIONAL
                        else {
                            warn 'Association failed: ' . $self->error
                              if $self->debug;
                        }

                        return $self->_redirect($cb);
                    }
                );
            }
        );
    }

    # From OP
    elsif (my $mode = $params->{'openid.mode'}) {
        my $ns = $params->{'openid.ns'};
        if (grep { $_ eq $mode } (qw/cancel error/)) {
            return $cb->($self, $openid_identifier, $mode);
        }
        elsif ($ns
            && $ns   eq $Protocol::OpenID::Discovery::VERSION_2_0
            && $mode eq 'setup_needed')
        {
            return $cb->($self, $openid_identifier, $mode);
        }
        elsif ((!$ns || $ns ne $Protocol::OpenID::Discovery::VERSION_2_0)
            && $mode eq 'user_setup_url')
        {
            return $cb->($self, $openid_identifier, $mode);
        }
        elsif ($mode eq 'id_res') {
            # Verify successful response
            return $self->_verify($params, $cb);
        }
        else {
            $self->error('Unknown mode');
            return $cb->($self, undef, 'error');
        }
    }
    # Do nothing
    else {
        return $cb->($self, undef, 'null');
    }
}

sub clear {
    my $self = shift;

    $self->clear_error;
    $self->clear_discovery;
    $self->clear_association;

    return $self;
}

sub _redirect {
    my $self = shift;
    my ($cb) = @_;

    my $discovery = $self->discovery;

    # Prepare params
    my $params = Protocol::OpenID::Parameters->new(
        mode     => 'checkid_setup',
        identity => $discovery->op_local_identifier,

        return_to => $self->return_to,
    );

    if ($discovery->protocol_version eq
        $Protocol::OpenID::Discovery::VERSION_2_0)
    {
        $params->param(ns         => $discovery->protocol_version);
        $params->param(claimed_id => $discovery->claimed_identifier);

        # TODO realm
        $params->param(realm => $self->return_to);
    }
    else {

        # TODO trust_root
        $params->param(trust_root => $self->return_to);
    }

    if (my $association = $self->association) {
        $params->param(assoc_handle => $association->assoc_handle);
    }

    # Prepare url for redirection
    my $location = $discovery->op_endpoint;

    # Redirect to OP
    return $cb->(
        $self, $discovery->claimed_identifier, 'redirect', $location,
        $params->to_hash_prefixed
    );
}

sub _associate {
    my $self = shift;
    my ($url, $cb) = @_;

    # No point to send association unless we can store it
    return $cb->($self, 'skip') unless $self->store_cb;

    my $association = $self->association;

    my $params = {
        'openid.ns'           => 'http://specs.openid.net/auth/2.0',
        'openid.mode'         => 'associate',
        'openid.assoc_type'   => $association->assoc_type,
        'openid.session_type' => $association->session_type
    };

    # If encrypted
    if (   $association->session_type eq 'DH-SHA1'
        || $association->session_type eq 'DH-SHA256')
    {
        $params->{'openid.dh_consumer_public'} =
          $association->dh_consumer_public;
    }

    $self->http_req_cb->(
        $self,
        $url => { method => 'POST', params => $params },
        sub {
            my ($self, $url, $args) = @_;

            my $status = $args->{status};
            my $body   = $args->{body};

            return $cb->($self, 'error') unless $status == 200;

            my $params = Protocol::OpenID::Parameters->new($body)->to_hash;

            unless (%$params
                && $params->{ns}
                && $params->{ns} eq 'http://specs.openid.net/auth/2.0')
            {
                $self->error('Wrong OpenID 2.0 response');
                return $cb->($self, 'error');
            }

            # Check if it is unsuccessful response
            if ($params->{error}) {

                # OP can suggest which session_type and assoc_type it supports
                # and we can try again unless we have already tried
                if ($params->{error_code} && $params->{error_code} eq 'unsupported-type') {
                    warn 'Association unsuccessful response' if $self->debug;

                    if (   $params->{session_type}
                        && $params->{assoc_type}
                        && !$self->_associate_counter)
                    {
                        $association->session_type($params->{session_type});
                        $association->assoc_type($params->{assoc_type});

                        warn 'Try again to create association' if $self->debug;

                        $self->_associate_counter(1);

                        return $self->_associate(
                            $url => sub {
                                my ($self, $result) = @_;

                                return $cb->($self, $result);
                            }
                        );
                    }
                }

                # Nothing we can do
                warn $params->{error} if $self->debug;
                $self->error($params->{error});
                return $cb->($self, 'error');
            }

            # Check if it is a successful response
            my $assoc_handle = $params->{assoc_handle};
            unless ($assoc_handle
                && $params->{session_type}
                && $params->{assoc_type}
                && $params->{expires_in})
            {
                $self->error('Wrong association response');
                return $cb->($self, 'error');
            }

            # Check the successful response itself
            if (   $params->{assoc_type} eq $association->assoc_type
                && $params->{session_type} eq $association->session_type)
            {

                # Check expires_in
                my $expires_in = $params->{expires_in};
                unless ($expires_in =~ m/^\d+$/) {
                    $self->error('Wrong expires_in');
                    return $cb->($self, 'error');
                }

                # There are different fields returned when using/not using
                # encryption
                if ($association->is_encrypted($self->discovery)) {
                    unless ($params->{dh_server_public}
                        && $params->{enc_mac_key})
                    {
                        $self->error('Required dh_server_public '
                              . 'and enc_mac_key are missing');
                        return $cb->($self, 'error');
                    }

                    $association->dh_server_public(
                        $params->{dh_server_public});
                    $association->enc_mac_key($params->{enc_mac_key});
                }
                else {
                    unless ($params->{mac_key}) {
                        $self->error('Required mac_key is missing');
                        return $cb->($self, 'error');
                    }
                    $association->mac_key($params->{mac_key});
                }

                # Check assoc_handle
                unless ($assoc_handle =~ m/^[\x21-\x86]{1,255}$/) {
                    $self->error('Wrong assoc_handle');
                    return $cb->($self, 'error');
                }

                # Save association
                $association->assoc_handle($assoc_handle);
                $association->expires(time + $expires_in);

                warn 'Association successful response' if $self->debug;

                return $cb->($self, 'ok');
            }

            $self->error('Wrong association response');
            return $cb->($self, 'error');
        }
    );
}

sub _verify {
    my $self = shift;
    my ($params, $cb) = @_;

    # Check return_to
    return $cb->($self, undef, 'error')
      unless $self->_return_to_is_valid(
        $params->{'openid.return_to'});

    # TODO: Check Discovered Information
    unless ($params->{'openid.identity'}) {
        $self->error('Wrong identity');
        return $cb->($self, undef, 'error');
    }

    my $ns = $params->{'openid.ns'}
      || $Protocol::OpenID::Discovery::VERSION_1_1;

    # Check nonce
    if ($ns eq $Protocol::OpenID::Discovery::VERSION_2_0) {
        return $cb->($self, undef, 'error')
          unless $self->_nonce_is_valid(
            $params->{'openid.response_nonce'});
    }

    # Look if we have invalidate_handle field, and automatically delete that
    # association from the store
    return $self->_verify_handle(
        $params,
        sub {
            my ($self, $is_valid) = @_;

            # Proceed with direct authentication unless handle is valid
            return $self->_authenticate_directly($params, $cb)
              unless $is_valid;

            # Check assocition, look into the store
            return $self->_verify_association(
                $params,
                sub {
                    my ($self, $is_valid) = @_;

                    # Proceed with direct authentication unless correct
                    # association handle was found
                    return $self->_authenticate_directly($params, $cb)
                      unless $is_valid;

                    # User is verified
                    return $cb->($self, undef, 'verified');
                }
            );
        }
    );
}

sub _return_to_is_valid {
    my $self = shift;
    my $param = shift;

    unless ($param && $self->return_to eq $param) {
        $self->error('Wrong return_to');

        return 0;
    }

    return 1;
}

sub _nonce_is_valid {
    my $self = shift;
    my $param = shift;

    my $nonce = Protocol::OpenID::Nonce->new;

    unless ($param && $nonce->parse($param)) {
        $self->error('Wrong nonce');
        return 0;
    }

    my $epoch = $nonce->epoch;
    my $time  = time;

    # Check if nonce isn't too far in the future (2 hours)
    if ($epoch < $time - 3600 * 2) {
        $self->error('Nonce is too old');
        return 0;
    }

    # Check if nonce isn't too old (2 hours)
    if ($epoch > $time + 3600 * 2) {
        $self->error('Nonce is in the future');
        return 0;
    }

    return 1;
}

sub _verify_handle {
    my $self = shift;
    my ($params, $cb) = @_;

    return $cb->($self, 0) unless $self->store_cb;

    if (my $handle = $params->{'openid.invalidate_handle'}) {
        warn "Removing handle '$handle'" if $self->debug;
        $self->remove_cb->($handle, sub {});
    }

    my $key = $params->{'openid.assoc_handle'};

    my $handle = $self->find_cb->($key);
    return $cb->($self, 0) unless $handle;
    warn "Handle '$handle' was found" if $self->debug;

    $self->association(Protocol::OpenID::Association->new(%$handle));

    return $cb->($self, 1);
}

sub _verify_association {
    my $self = shift;
    my ($params, $cb) = @_;

    my $association = $self->association;
    return $cb->($self, 0) unless $association;

    my $op_signature = $params->{'openid.sig'};

    my $sg = Protocol::OpenID::Signature->new(
        algorithm => $association->assoc_type,
        params    => $params
    );

    my $rp_signature = $sg->calculate($association->enc_mac_key);

    return $cb->($self, 0) unless $op_signature eq $rp_signature;

    warn 'Signatures match' if $self->debug;
    return $cb->($self, 1);
}

sub _authenticate_directly {
    my ($self, $params, $cb) = @_;

    my $op_endpoint;

    my $ns = $params->{'openid.ns'};

    if ($ns && $ns eq $Protocol::OpenID::Discovery::VERSION_2_0) {
        $op_endpoint = $params->{'openid.op_endpoint'};
    }

    # Forced to make a discovery again :(
    else {
        my $id = Protocol::OpenID::Identifier->new(
            $params->{'openid.identity'});

        $self->clear_discovery;

        return $self->call(
            discover => [$self, $id] => sub {
                my ($ctl, $args, $is_done) = @_;

                # Return if discovery was unsuccessful
                return $cb->($self, undef, 'error')
                  unless $self->discovery;

                $op_endpoint = $self->discovery->op_endpoint;

                # Verifying Directly with the OpenID Provider
                return $self->_authenticate_directly_req($op_endpoint,
                    {params => $params}, $cb);
            }
        );
    }

    my $discovery = Protocol::OpenID::Discovery->new(
        claimed_identifier => $ns eq
          $Protocol::OpenID::Discovery::VERSION_2_0
        ? $params->{'openid.claimed_id'}
        : $params->{'openid.identity'}
    );
    $self->discovery($discovery);

    # Verifying Directly with the OpenID Provider
    return $self->_authenticate_directly_req($op_endpoint,
        {params => $params}, $cb);
}

sub _authenticate_directly_req {
    my ($self, $url, $args, $cb) = @_;

    warn 'Direct authentication' if $self->debug;

    # When using Direct Authentication we must take all the params we've got
    # from the OP (instead of the mode) and send them back
    my $params =
      {%{$args->{params}}, 'openid.mode' => 'check_authentication'};

    return $self->http_req_cb->(
        $self,
        $url => {method => 'POST', params => $params},
        sub {
            my ($self, $op_endpoint, $args) = @_;

            my $status = $args->{status};
            my $body   = $args->{body};

            unless ($status && $status == 200) {
                $self->error('Wrong provider direct authentication response status');
                return $cb->($self, undef, 'error');
            }

            my $params = Protocol::OpenID::Parameters->new($body);
            unless ($params->param('is_valid')) {
                warn $body if $self->debug;
                $self->error('is_valid field is missing');
                return $cb->($self, undef, 'error');
            }

            if ($params->param('is_valid') eq 'true') {
                # Finally verified user
                return $cb->($self, $self->discovery->claimed_identifier, 'verified');
            }

            $self->error('Not a valid user');

            if ($params->param('invalidate_handle')) {
                die 'SUPPORT ME!';
            }

            return $cb->($self, undef, 'error');
        }
    );
}

1;
