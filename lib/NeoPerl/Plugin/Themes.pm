package NeoPerl::Plugin::Themes;

use strict;
use warnings;

our $VERSION = '0.01';

my %THEMES = (
    aix_amber => {
        name            => 'aix_amber',
        label           => 'AIX Amber Phosphor',
        bg              => '#000000',
        bg_dark         => '#000000',
        bg_float        => '#080500',
        bg_sidebar      => '#050300',
        bg_statusline   => '#0d0800',
        bg_tabline      => '#080500',
        bg_highlight    => '#170f00',
        bg_visual       => '#3b2400',
        bg_search       => '#4f3000',
        fg              => '#ffb000',
        fg_dim          => '#a86e00',
        fg_gutter       => '#664200',
        border          => '#4d3100',
        border_focus    => '#ffb000',
        accent          => '#ffb000',
        accent2         => '#ff8c00',
        cursor          => '#ffb000',
        cursor_fg       => '#000000',
        mode_normal     => '#ffb000',
        mode_insert     => '#ffd266',
        mode_visual     => '#ff8c00',
        mode_replace    => '#ff4d2e',
        mode_command    => '#ffe08a',
        mode_terminal   => '#d99a00',
        diag_error      => '#ff4d2e',
        diag_warn       => '#ffb000',
        diag_info       => '#e09a3a',
        diag_hint       => '#99661a',
        git_add         => '#b8e048',
        git_change      => '#ffb000',
        git_delete      => '#ff6242',
        diff_add_bg     => '#121c04',
        diff_del_bg     => '#260a04',
        diff_change_bg  => '#1c1200',
        diff_add_fg     => '#b8e048',
        diff_del_fg     => '#ff6242',
        ghost_text      => '#6e4700',
        virt_text       => '#b37400',
        heat_cold       => '#664200',
        heat_warm       => '#cc7a00',
        heat_hot        => '#ff9900',
        heat_crit       => '#ff4d2e',
        match_char      => '#ffe49e',
        breakpoint      => '#ff4d2e',
        pc_line         => '#2b1a00',
        syntax          => {
            normal       => '#ffb000',
            keyword      => '#ffd873',
            string       => '#e6a84c',
            comment      => '#7a4f00',
            number       => '#ff7b00',
            function     => '#ffe49e',
            type         => '#ff9500',
            variable     => '#ffb000',
            operator     => '#cc8400',
            constant     => '#ff6a00',
            preprocessor => '#ffa633',
            tag          => '#ff7b00',
            attribute    => '#ffd266',
            punctuation  => '#cc8400',
            heading      => '#ffe49e',
            link         => '#ffd266',
        },
    },
    tokyonight => {
        name            => 'tokyonight',
        label           => 'Tokyo Night Storm',
        bg              => '#24283b',
        bg_dark         => '#1f2335',
        bg_float        => '#1f2335',
        bg_sidebar      => '#1d202f',
        bg_statusline   => '#1a1e2e',
        bg_tabline      => '#1a1e2e',
        bg_highlight    => '#292e42',
        bg_visual       => '#364a82',
        bg_search       => '#3d59a1',
        fg              => '#c0caf5',
        fg_dim          => '#737aa2',
        fg_gutter       => '#3b4261',
        border          => '#3b4261',
        border_focus    => '#7aa2f7',
        accent          => '#7aa2f7',
        accent2         => '#bb9af7',
        cursor          => '#c0caf5',
        cursor_fg       => '#1f2335',
        mode_normal     => '#7aa2f7',
        mode_insert     => '#9ece6a',
        mode_visual     => '#bb9af7',
        mode_replace    => '#f7768e',
        mode_command    => '#e0af68',
        mode_terminal   => '#73daca',
        diag_error      => '#db4b4b',
        diag_warn       => '#e0af68',
        diag_info       => '#0db9d7',
        diag_hint       => '#1abc9c',
        git_add         => '#449dab',
        git_change      => '#6183bb',
        git_delete      => '#914c54',
        diff_add_bg     => '#20303b',
        diff_del_bg     => '#37222c',
        diff_change_bg  => '#1f2231',
        diff_add_fg     => '#9ece6a',
        diff_del_fg     => '#f7768e',
        ghost_text      => '#565f89',
        virt_text       => '#6b759f',
        heat_cold       => '#3d59a1',
        heat_warm       => '#e0af68',
        heat_hot        => '#ff9e64',
        heat_crit       => '#f7768e',
        match_char      => '#ff9e64',
        breakpoint      => '#f7768e',
        pc_line         => '#2e3c64',
        syntax          => {
            normal       => '#c0caf5',
            keyword      => '#9d7cd8',
            string       => '#9ece6a',
            comment      => '#565f89',
            number       => '#ff9e64',
            function     => '#7aa2f7',
            type         => '#2ac3de',
            variable     => '#c0caf5',
            operator     => '#89ddff',
            constant     => '#ff9e64',
            preprocessor => '#7dcfff',
            tag          => '#f7768e',
            attribute    => '#7aa2f7',
            punctuation  => '#89ddff',
            heading      => '#7aa2f7',
            link         => '#73daca',
        },
    },
    catppuccin => {
        name            => 'catppuccin',
        label           => 'Catppuccin Mocha',
        bg              => '#1e1e2e',
        bg_dark         => '#181825',
        bg_float        => '#181825',
        bg_sidebar      => '#181825',
        bg_statusline   => '#11111b',
        bg_tabline      => '#11111b',
        bg_highlight    => '#2a2b3c',
        bg_visual       => '#45475a',
        bg_search       => '#3e5767',
        fg              => '#cdd6f4',
        fg_dim          => '#7f849c',
        fg_gutter       => '#45475a',
        border          => '#45475a',
        border_focus    => '#89b4fa',
        accent          => '#89b4fa',
        accent2         => '#cba6f7',
        cursor          => '#f5e0dc',
        cursor_fg       => '#1e1e2e',
        mode_normal     => '#89b4fa',
        mode_insert     => '#a6e3a1',
        mode_visual     => '#cba6f7',
        mode_replace    => '#f38ba8',
        mode_command    => '#f9e2af',
        mode_terminal   => '#94e2d5',
        diag_error      => '#f38ba8',
        diag_warn       => '#f9e2af',
        diag_info       => '#89dceb',
        diag_hint       => '#94e2d5',
        git_add         => '#a6e3a1',
        git_change      => '#f9e2af',
        git_delete      => '#f38ba8',
        diff_add_bg     => '#22332a',
        diff_del_bg     => '#36232d',
        diff_change_bg  => '#25293d',
        diff_add_fg     => '#a6e3a1',
        diff_del_fg     => '#f38ba8',
        ghost_text      => '#6c7086',
        virt_text       => '#7f849c',
        heat_cold       => '#74c7ec',
        heat_warm       => '#f9e2af',
        heat_hot        => '#fab387',
        heat_crit       => '#f38ba8',
        match_char      => '#fab387',
        breakpoint      => '#f38ba8',
        pc_line         => '#313244',
        syntax          => {
            normal       => '#cdd6f4',
            keyword      => '#cba6f7',
            string       => '#a6e3a1',
            comment      => '#6c7086',
            number       => '#fab387',
            function     => '#89b4fa',
            type         => '#f9e2af',
            variable     => '#cdd6f4',
            operator     => '#89dceb',
            constant     => '#fab387',
            preprocessor => '#f5c2e7',
            tag          => '#89b4fa',
            attribute    => '#f9e2af',
            punctuation  => '#9399b2',
            heading      => '#89b4fa',
            link         => '#94e2d5',
        },
    },
    gruvbox => {
        name            => 'gruvbox',
        label           => 'Gruvbox Dark',
        bg              => '#282828',
        bg_dark         => '#1d2021',
        bg_float        => '#1d2021',
        bg_sidebar      => '#1d2021',
        bg_statusline   => '#3c3836',
        bg_tabline      => '#1d2021',
        bg_highlight    => '#32302f',
        bg_visual       => '#504945',
        bg_search       => '#665c54',
        fg              => '#ebdbb2',
        fg_dim          => '#928374',
        fg_gutter       => '#665c54',
        border          => '#504945',
        border_focus    => '#fabd2f',
        accent          => '#83a598',
        accent2         => '#d3869b',
        cursor          => '#ebdbb2',
        cursor_fg       => '#282828',
        mode_normal     => '#83a598',
        mode_insert     => '#b8bb26',
        mode_visual     => '#d3869b',
        mode_replace    => '#fb4934',
        mode_command    => '#fabd2f',
        mode_terminal   => '#8ec07c',
        diag_error      => '#fb4934',
        diag_warn       => '#fabd2f',
        diag_info       => '#83a598',
        diag_hint       => '#8ec07c',
        git_add         => '#b8bb26',
        git_change      => '#83a598',
        git_delete      => '#fb4934',
        diff_add_bg     => '#2d3625',
        diff_del_bg     => '#3d2422',
        diff_change_bg  => '#2c3336',
        diff_add_fg     => '#b8bb26',
        diff_del_fg     => '#fb4934',
        ghost_text      => '#7c6f64',
        virt_text       => '#928374',
        heat_cold       => '#83a598',
        heat_warm       => '#fabd2f',
        heat_hot        => '#fe8019',
        heat_crit       => '#fb4934',
        match_char      => '#fe8019',
        breakpoint      => '#fb4934',
        pc_line         => '#3c3836',
        syntax          => {
            normal       => '#ebdbb2',
            keyword      => '#fb4934',
            string       => '#b8bb26',
            comment      => '#928374',
            number       => '#d3869b',
            function     => '#b8bb26',
            type         => '#fabd2f',
            variable     => '#83a598',
            operator     => '#fe8019',
            constant     => '#d3869b',
            preprocessor => '#8ec07c',
            tag          => '#fb4934',
            attribute    => '#fabd2f',
            punctuation  => '#a89984',
            heading      => '#fabd2f',
            link         => '#83a598',
        },
    },
    kanagawa => {
        name            => 'kanagawa',
        label           => 'Kanagawa Wave',
        bg              => '#1f1f28',
        bg_dark         => '#16161d',
        bg_float        => '#16161d',
        bg_sidebar      => '#181820',
        bg_statusline   => '#16161d',
        bg_tabline      => '#16161d',
        bg_highlight    => '#2a2a37',
        bg_visual       => '#2d4f67',
        bg_search       => '#2d4f67',
        fg              => '#dcd7ba',
        fg_dim          => '#727169',
        fg_gutter       => '#54546d',
        border          => '#54546d',
        border_focus    => '#7e9cd8',
        accent          => '#7e9cd8',
        accent2         => '#957fb8',
        cursor          => '#c8c093',
        cursor_fg       => '#1f1f28',
        mode_normal     => '#7e9cd8',
        mode_insert     => '#98bb6c',
        mode_visual     => '#957fb8',
        mode_replace    => '#e46876',
        mode_command    => '#e6c384',
        mode_terminal   => '#7aa89f',
        diag_error      => '#e82424',
        diag_warn       => '#ff9e3b',
        diag_info       => '#658594',
        diag_hint       => '#6a9589',
        git_add         => '#76946a',
        git_change      => '#dca561',
        git_delete      => '#c34043',
        diff_add_bg     => '#2b3328',
        diff_del_bg     => '#43242b',
        diff_change_bg  => '#252535',
        diff_add_fg     => '#98bb6c',
        diff_del_fg     => '#e46876',
        ghost_text      => '#727169',
        virt_text       => '#727169',
        heat_cold       => '#7fb4ca',
        heat_warm       => '#e6c384',
        heat_hot        => '#ffa066',
        heat_crit       => '#e46876',
        match_char      => '#ffa066',
        breakpoint      => '#e46876',
        pc_line         => '#363646',
        syntax          => {
            normal       => '#dcd7ba',
            keyword      => '#957fb8',
            string       => '#98bb6c',
            comment      => '#727169',
            number       => '#d27e99',
            function     => '#7e9cd8',
            type         => '#7aa89f',
            variable     => '#dcd7ba',
            operator     => '#c0a36e',
            constant     => '#ffa066',
            preprocessor => '#e46876',
            tag          => '#e6c384',
            attribute    => '#7fb4ca',
            punctuation  => '#9cabca',
            heading      => '#7e9cd8',
            link         => '#7fb4ca',
        },
    },
);

sub list {
    return sort keys %THEMES;
}

sub exists_theme {
    my ($class, $name) = @_;
    return 0 unless defined $name;
    return exists $THEMES{ lc $name } ? 1 : 0;
}

sub get {
    my ($class, $name) = @_;
    my $key = defined($name) ? lc($name) : 'aix_amber';
    my $theme = $THEMES{$key} || $THEMES{aix_amber};
    my %copy = %{$theme};
    $copy{syntax} = { %{ $theme->{syntax} } };
    return \%copy;
}

sub register {
    my ($class, $name, $palette) = @_;
    die "Theme name and hashref palette required"
        unless defined $name && ref($palette) eq 'HASH';
    my $key  = lc $name;
    my $base = $class->get('aix_amber');
    my %merged = (%{$base}, %{$palette}, name => $key);
    if (ref($palette->{syntax}) eq 'HASH') {
        $merged{syntax} = { %{ $base->{syntax} }, %{ $palette->{syntax} } };
    }
    $THEMES{$key} = \%merged;
    return $class->get($key);
}

sub hex_to_rgb {
    my ($class_or_hex, $maybe_hex) = @_;
    my $hex = defined($maybe_hex) ? $maybe_hex : $class_or_hex;
    return (0, 0, 0) unless defined $hex;
    $hex =~ s/^#//;
    if ($hex =~ /^([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/) {
        return (hex($1), hex($2), hex($3));
    }
    return (0, 0, 0);
}

sub syntax_color {
    my ($class, $theme, $group) = @_;
    $theme = $class->get($theme) unless ref($theme) eq 'HASH';
    $group = 'normal' unless defined $group;
    return $theme->{syntax}{$group}
        // $theme->{syntax}{ lc $group }
        // $theme->{fg};
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::Themes - Built-in color schemes for NeoPerl::MT

=head1 SYNOPSIS

    use NeoPerl::Plugin::Themes;
    my $theme = NeoPerl::Plugin::Themes->get('aix_amber');
    my ($r, $g, $b) = NeoPerl::Plugin::Themes->hex_to_rgb($theme->{bg});

=head1 DESCRIPTION

Provides five built-in dark color palettes (C<aix_amber> default,
C<tokyonight>, C<catppuccin>, C<gruvbox>, and C<kanagawa>) plus registration
of custom palettes for both the GPU canvas and 24-bit ANSI terminal frontends.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
