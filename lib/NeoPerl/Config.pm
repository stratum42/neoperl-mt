package NeoPerl::Config;

use strict;
use warnings;
use File::Spec;
use Cwd qw(abs_path);

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    return bless {
        editor       => $opts{editor},
        loaded_files => [],
        errors       => [],
    }, $class;
}

sub loaded_files {
    my ($self) = @_;
    return @{ $self->{loaded_files} };
}

sub errors {
    my ($self) = @_;
    return @{ $self->{errors} };
}

sub discover_init_files {
    my ($self, $cwd) = @_;
    my @files;

    # 1. Explicit env override or XDG user init.pl
    if (defined $ENV{NEOPERL_INIT} && -f $ENV{NEOPERL_INIT}) {
        push @files, $ENV{NEOPERL_INIT};
    }
    else {
        my $xdg = $ENV{XDG_CONFIG_HOME};
        my $home = $ENV{HOME} || $ENV{USERPROFILE};
        my $base = (defined $xdg && length $xdg)
            ? File::Spec->catdir($xdg, 'neoperl')
            : (defined $home ? File::Spec->catdir($home, '.config', 'neoperl') : undef);
        if (defined $base) {
            my $init_pl = File::Spec->catfile($base, 'init.pl');
            push @files, $init_pl if -f $init_pl;
        }
    }

    # 2. Project-local .neoperl.pl (walk upward from cwd to root)
    $cwd ||= ($self->{editor} ? $self->{editor}->cwd : '.');
    my $dir = eval { abs_path($cwd) } || $cwd;
    my @project_files;
    my %seen;
    while (defined $dir && length $dir && !$seen{$dir}++) {
        my $local_rc = File::Spec->catfile($dir, '.neoperl.pl');
        if (-f $local_rc) {
            unshift @project_files, $local_rc;
            last;
        }
        my $parent = File::Spec->catdir($dir, File::Spec->updir);
        my $norm = eval { abs_path($parent) };
        last if !defined $norm || $norm eq $dir;
        $dir = $norm;
    }
    push @files, @project_files;

    return @files;
}

sub load_all {
    my ($self, %opts) = @_;
    my @files = $self->discover_init_files($opts{cwd});
    my $loaded = 0;
    for my $file (@files) {
        $loaded++ if $self->load_file($file);
    }
    return $loaded;
}

sub load_file {
    my ($self, $path) = @_;
    return 0 unless defined $path && -f $path;

    open my $fh, '<:encoding(UTF-8)', $path or do {
        my $err = "Failed to open config $path: $!";
        push @{ $self->{errors} }, $err;
        $self->{editor}->notify($err, 'error') if $self->{editor};
        return 0;
    };
    local $/;
    my $code = <$fh>;
    close $fh;

    return $self->eval_config($code, $path);
}

sub eval_config {
    my ($self, $code, $source_name) = @_;
    $source_name ||= '<inline>';
    my $editor = $self->{editor};
    my $vim    = $editor ? $editor->api : undef;

    my $ok = 0;
    my $err;
    {
        my $sandbox = sub {
            my ($vim_arg, $editor_arg, $src) = @_;
            my $vim    = $vim_arg;
            my $editor = $editor_arg;
            local $@;
            my $wrapped = qq{#line 1 "$source_name"\n$src\n1;\n};
            my $res = eval $wrapped;
            return ($res ? 1 : 0, $@);
        };
        ($ok, $err) = $sandbox->($vim, $editor, $code);
    }

    if (!$ok) {
        $err ||= "Unknown error evaluating $source_name";
        chomp $err;
        my $msg = "Config error ($source_name): $err";
        push @{ $self->{errors} }, $msg;
        $editor->notify($msg, 'error') if $editor;
        return 0;
    }

    push @{ $self->{loaded_files} }, $source_name;
    return 1;
}

1;

__END__

=head1 NAME

NeoPerl::Config - Configuration discovery and Perl init.pl loader for NeoPerl::MT

=head1 SYNOPSIS

    use NeoPerl::Config;
    my $cfg = NeoPerl::Config->new(editor => $editor);
    $cfg->load_all;
    $cfg->load_file('init.pl');

=head1 DESCRIPTION

Locates and evaluates user C<init.pl> and project-local C<.neoperl.pl> files
with C<$vim> (L<NeoPerl::API>) and C<$editor> (L<NeoPerl::Editor>) bound in
lexical scope.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
