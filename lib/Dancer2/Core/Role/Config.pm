package Dancer2::Core::Role::Config;

# ABSTRACT: Config role for Dancer2 core objects

use Moo::Role;

=head1 DESCRIPTION

Provides a C<config> attribute that feeds itself by finding and parsing
configuration files.

Also provides a C<setting()> method which is supposed to be used by externals to
read/write config entries.

=cut

use Dancer2::Core::Factory;
use File::Spec;
use Config::Any;
use Dancer2::Core::Types;
use Dancer2::FileUtils qw/dirname path/;
use Hash::Merge::Simple;
use Carp 'croak', 'carp';

requires 'location';

=method config_location

Gets the location from the configuration. Same as C<< $object->location >>.

=cut

has config_location => (
    is      => 'ro',
    isa     => ReadableFilePath,
    lazy    => 1,
    default => sub { $ENV{DANCER_CONFDIR} || $_[0]->location },
);

# The type for this attribute is Str because we don't require
# an existing directory with configuration files for the
# environments.  An application without environments is still
# valid and works.
has environments_location => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {
        $ENV{DANCER_ENVDIR}
          || File::Spec->catdir( $_[0]->config_location, 'environments' )
          || File::Spec->catdir( $_[0]->location,        'environments' );
    },
);

# TODO: make readonly and add method rebuild_config?
has config => (
    is      => 'rw',
    isa     => HashRef,
    lazy    => 1,
    builder => '_build_config',
);

has engines => (
    is      => 'ro',
    isa     => HashRef,
    lazy    => 1,
    builder => '_build_engines',
);

has environment => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    builder => '_build_environment',
);

sub settings { shift->config }

sub setting {
    my $self = shift;
    my @args = @_;

    return ( scalar @args == 1 )
      ? $self->settings->{ $args[0] }
      : $self->_set_config_entries(@args);
}

sub has_setting {
    my ( $self, $name ) = @_;
    return exists $self->config->{$name};
}

has config_files => (
    is      => 'rw',
    lazy    => 1,
    isa     => ArrayRef,
    builder => '_build_config_files',
);

sub _build_config_files {
    my ($self) = @_;
    my $location = $self->config_location;

    # an undef location means no config files for the caller
    return [] unless defined $location;

    my $running_env = $self->environment;
    my @exts        = Config::Any->extensions;
    my @files;

    foreach my $ext (@exts) {
        foreach my $file ( [ $location, "config.$ext" ],
            [ $self->environments_location, "$running_env.$ext" ] )
        {
            my $path = path( @{$file} );
            next if !-r $path;

            push @files, $path;
        }
    }

    return [ sort @files ];
}

sub load_config_file {
    my ( $self, $file ) = @_;
    my $config;

    eval {
        my @files = ($file);
        my $tmpconfig =
          Config::Any->load_files( { files => \@files, use_ext => 1 } )->[0];
        ( $file, $config ) = %{$tmpconfig};
    };
    if ( my $err = $@ || ( !$config ) ) {
        croak "Unable to parse the configuration file: $file: $@";
    }

    # TODO handle mergeable entries
    return $config;
}

sub get_postponed_hooks {
    my ($self) = @_;
    return $self->postponed_hooks;
    # XXX FIXME
    # return ( ref($self) eq 'Dancer2::Core::App' )
    #   ? (
    #     ( defined $self->server )
    #     ? $self->server->runner->postponed_hooks
    #     : {}
    #   )
    #   : $self->can('postponed_hooks') ? $self->postponed_hooks
    #   :                                 {};
}

# private

sub _build_config {
    my ($self) = @_;
    my $location = $self->config_location;

    my $default = {};
    $default = $self->default_config
      if $self->can('default_config');

    my $config = Hash::Merge::Simple->merge(
        $default,
        map { $self->load_config_file($_) } @{ $self->config_files }
    );

    $config = $self->_normalize_config($config);
    return $config;
}

sub _set_config_entries {
    my ( $self, @args ) = @_;
    my $no = scalar @args;
    while (@args) {
        $self->_set_config_entry( shift(@args), shift(@args) );
    }
    return $no;
}

sub _set_config_entry {
    my ( $self, $name, $value ) = @_;

    $value = $self->_normalize_config_entry( $name, $value );
    $value = $self->_compile_config_entry( $name, $value, $self->config );
    $self->config->{$name} = $value;
}

sub _normalize_config {
    my ( $self, $config ) = @_;

    foreach my $key ( keys %{$config} ) {
        my $value = $config->{$key};
        $config->{$key} = $self->_normalize_config_entry( $key, $value );
    }
    return $config;
}

sub _compile_config {
    my ( $self, $config ) = @_;

    foreach my $key ( keys %{$config} ) {
        my $value = $config->{$key};
        $config->{$key} =
          $self->_compile_config_entry( $key, $value, $config );
    }
    return $config;
}

my $_normalizers = {
    charset => sub {
        my ($charset) = @_;
        return $charset if !length( $charset || '' );

        require Encode;
        my $encoding = Encode::find_encoding($charset);
        croak
          "Charset defined in configuration is wrong : couldn't identify '$charset'"
          unless defined $encoding;
        my $name = $encoding->name;

        # Perl makes a distinction between the usual perl utf8, and the strict
        # utf8 charset. But we don't want to make this distinction
        $name = 'utf-8' if $name eq 'utf-8-strict';
        return $name;
    },
};

sub _normalize_config_entry {
    my ( $self, $name, $value ) = @_;
    $value = $_normalizers->{$name}->($value)
      if exists $_normalizers->{$name};
    return $value;
}

my $_setters = {
    logger => sub {
        my ( $self, $value, $config ) = @_;
        return $value if ref($value);
        my $l = $self->_build_engine_logger($value, $config);
        $self->engines->{logger} = $l;
        return $l;
    },

    session => sub {
        my ( $self, $value, $config ) = @_;
        return $value if ref($value);
        my $s = $self->_build_engine_session($value, $config);
        $self->engines->{session} = $s;
        return $s;
    },

    template => sub {
        my ( $self, $value, $config ) = @_;
        return if ref($value);
        my $t = $self->_build_engine_template($value, $config);
        $self->engines->{template} = $t;
        return $t;
    },

#    route_cache => sub {
#        my ($setting, $value) = @_;
#        require Dancer2::Route::Cache;
#        Dancer2::Route::Cache->reset();
#    },

    serializer => sub {
        my ( $self, $value, $config ) = @_;
        my $s = $self->_build_engine_serializer($value, $config);
        $self->engines->{serializer} = $s;
        return $s;
    },

    import_warnings => sub {
        my ( $self, $value ) = @_;
        $^W = $value ? 1 : 0;
    },

    traces => sub {
        my ( $self, $traces ) = @_;
        require Carp;
        $Carp::Verbose = $traces ? 1 : 0;
    },

    views => sub {
        my ( $self, $value, $config ) = @_;
        $self->engine('template')->views($value);
    },

    layout => sub {
        my ( $self, $value, $config ) = @_;
        $self->engine('template')->layout($value);
    },
};

sub _compile_config_entry {
    my ( $self, $name, $value, $config ) = @_;

    my $trigger = $_setters->{$name};
    return $value unless defined $trigger;

    return $trigger->( $self, $value, $config );
}

sub _get_config_for_engine {
    my ( $self, $engine, $name, $config ) = @_;

    my $default_config = {
        environment => $self->environment,
        location    => $self->config_location,
    };
    return $default_config unless defined $config->{engines};

    if ( !defined $config->{engines}{$engine} ) {
        return $default_config;
    }

    my $engine_config = $config->{engines}{$engine}{$name} || {};
    return { %{$default_config}, %{$engine_config}, } || $default_config;
}

sub _build_engines {
    my $self    = shift;

    # Dancer2 supports 4 types of engines:
    # - logger
    # - session
    # - template
    # - serializer
    # we build them first
    return {
        logger     => $self->_build_engine_logger(),
        session    => $self->_build_engine_session(),
        template   => $self->_build_engine_template(),
        serializer => $self->_build_engine_serializer(),
    };
}

sub _build_engine_logger {
    my ($self, $value, $config) = @_;

    # _build_engine_x is also called by a trigger
    # so the value and config can be passed as arg
    $config = $self->config     if !defined $config;
    $value  = $config->{logger} if !defined $value;

    # if the existing logger is an object, we pass
    return $value if ref($value);

    # by default, create a logger 'console'
    $value = 'console' if !defined $value;

    # get the options for the engine
    my $engine_options =
        $self->_get_config_for_engine( logger => $value, $config );

    # keep compatibility with old 'log' keyword to define log level.
    # XXX actually, since this is dancer2, there's no reason to keep this as a compatiblity
    if (   !exists( $engine_options->{log_level} )
               and exists( $config->{log} ) )
        {
            $engine_options->{log_level} = $config->{log};
        }

    # create the object
    return Dancer2::Core::Factory->create(
        logger => $value,
        %{$engine_options},
        app_name        => $self->name,
        postponed_hooks => $self->get_postponed_hooks
    );
    # XXX The fact that we have to store it in the config is really ugly.
    # I think the right way to access an engine is to always call $self->engine and
    # NEVER $self->config->{logger}.
}

sub _build_engine_session {
    my ($self, $value, $config)  = @_;

    $config = $self->config if !defined $config;
    $value  = $config->{'session'} if !defined $value;

    $value = 'simple' if !defined $value;
    return $value if ref($value);

    my $engine_options =
          $self->_get_config_for_engine( session => $value, $config );

    return Dancer2::Core::Factory->create(
        session => $value,
        %{$engine_options},
        postponed_hooks => $self->get_postponed_hooks,
    );
}

sub _build_engine_template {
    my ($self, $value, $config)  = @_;

    $config = $self->config if !defined $config;
    $value = $config->{'template'} if !defined $value;

    return undef  if !defined $value;
    return $value if ref($value);

    my $engine_options =
          $self->_get_config_for_engine( template => $value, $config );

    my $engine_attrs = { config => $engine_options };
    $engine_attrs->{layout} ||= $config->{layout};
    $engine_attrs->{views}  ||= $config->{views}
        || path( $self->location, 'views' );

    return Dancer2::Core::Factory->create(
        template => $value,
        %{$engine_attrs},
        postponed_hooks => $self->get_postponed_hooks,
    );
}

sub _build_engine_serializer {
    my ($self, $value, $config) = @_;

    $config = $self->config if !defined $config;
    $value  = $config->{serializer} if !defined $value;

    return undef  if !defined $value;
    return $value if ref($value);

    my $engine_options =
        $self->_get_config_for_engine( serializer => $value, $config );

    return Dancer2::Core::Factory->create(
        serializer      => $value,
        config          => $engine_options,
        postponed_hooks => $self->get_postponed_hooks,
    );
}

1;
