package NeoPerl::Plugin::XSDev::Debugger;

use strict;
use warnings;

use File::Basename ();
use File::Spec ();
use IPC::Open2 ();
use Time::HiRes ();

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    return bless {
        runner        => $opts{runner},
        backend       => undef,    # 'gdb' or 'lldb'
        session_pid   => undef,
        session_in    => undef,
        session_out   => undef,
        breakpoints   => {},       # "file:line" => { file, line, condition, enabled, id }
        watches       => [],
        state         => {
            active          => 0,
            backend         => undef,
            target          => undef,
            pc_file         => undef,
            pc_line         => undef,
            stop_reason     => undef,
            backtrace       => [],
            locals          => [],
            threads         => [],
            registers       => {},
            power_registers => { gpr => {}, vsx => {}, spr => {} },
            sv_inspector    => [],
        },
        _next_bp_id   => 1,
    }, $class;
}

sub state       { $_[0]{state} }
sub breakpoints { $_[0]{breakpoints} }

# -------------------------------------------------------------------------
# 1. Breakpoint & watchpoint management + gutter extmarks (xs_debug)
# -------------------------------------------------------------------------

sub _bp_key {
    my ($file, $line) = @_;
    return File::Basename::basename($file // '') . ':' . (($line || 1) + 0);
}

sub set_breakpoint {
    my ($self, $file, $line, %opts) = @_;
    my $key = _bp_key($file, $line);
    my $bp = {
        id        => $self->{_next_bp_id}++,
        file      => $file,
        line      => ($line || 1) + 0,
        condition => $opts{condition},
        enabled   => 1,
    };
    $self->{breakpoints}{$key} = $bp;

    if ($self->{session_in}) {
        if (($self->{backend} || '') eq 'gdb') {
            my $cond = defined $bp->{condition} ? "-c \"$bp->{condition}\" " : '';
            $self->_send_session("-break-insert ${cond}\"$file\":$bp->{line}\n");
        }
        elsif (($self->{backend} || '') eq 'lldb') {
            my $cmd = "breakpoint set --file $file --line $bp->{line}";
            $cmd .= " --condition '$bp->{condition}'" if defined $bp->{condition};
            $self->_send_session("$cmd\n");
        }
    }
    return $bp;
}

sub remove_breakpoint {
    my ($self, $file, $line) = @_;
    my $key = _bp_key($file, $line);
    return delete $self->{breakpoints}{$key};
}

sub toggle_breakpoint {
    my ($self, $file, $line, %opts) = @_;
    my $key = _bp_key($file, $line);
    if (exists $self->{breakpoints}{$key}) {
        $self->remove_breakpoint($file, $line);
        return { action => 'removed', file => $file, line => $line + 0 };
    }
    my $bp = $self->set_breakpoint($file, $line, %opts);
    return { action => 'added', breakpoint => $bp };
}

sub list_breakpoints {
    my ($self) = @_;
    return [ sort { ($a->{file} cmp $b->{file}) || ($a->{line} <=> $b->{line}) } values %{ $self->{breakpoints} } ];
}

sub add_watch {
    my ($self, $expr) = @_;
    return unless defined $expr && length $expr;
    push @{ $self->{watches} }, { expr => $expr, value => undef }
        unless grep { $_->{expr} eq $expr } @{ $self->{watches} };
    return $self->{watches};
}

sub paint_debug_marks {
    my ($self, $buf, %opts) = @_;
    return 0 unless $buf;
    my $ns = 'xs_debug';
    my $core_buf = ($buf->can('core') && $buf->core) ? $buf->core : $buf;

    if ($buf->can('clear_namespace')) {
        $buf->clear_namespace($ns);
    }
    elsif ($core_buf->can('clear_namespace')) {
        $core_buf->clear_namespace($ns);
    }

    my $buf_path = $opts{file_path};
    $buf_path = $buf->path     if !defined($buf_path) && $buf->can('path');
    $buf_path = $buf->name     if !defined($buf_path) && $buf->can('name');
    $buf_path = $buf->filename if !defined($buf_path) && $buf->can('filename');
    $buf_path //= '';
    my $buf_base = length($buf_path) ? File::Basename::basename($buf_path) : '';
    my $count = 0;

    for my $bp (@{ $self->list_breakpoints }) {
        my $bp_base = length($bp->{file} // '') ? File::Basename::basename($bp->{file}) : '';
        next unless !length($buf_base) || $bp_base eq $buf_base;
        my $mark = {
            namespace => $ns,
            line      => $bp->{line} - 1,
            col       => 0,
            sign_text => '●',
            sign_hl   => 'XSDebugBreakpoint',
            priority  => 60,
        };
        if ($buf->can('set_extmark')) {
            eval { $buf->set_extmark($ns, $bp->{line} - 1, 0, $mark) };
        }
        elsif ($core_buf->can('set_extmark')) {
            eval { $core_buf->set_extmark($ns, $bp->{line} - 1, 0, $mark) };
        }
        $count++;
    }

    my $pc_file = $self->{state}{pc_file};
    my $pc_line = $self->{state}{pc_line};
    if (defined $pc_line && $pc_line > 0
        && (!length($buf_base) || !defined($pc_file) || !length($pc_file) || File::Basename::basename($pc_file) eq $buf_base))
    {
        my $mark = {
            namespace => $ns,
            line      => $pc_line - 1,
            col       => 0,
            sign_text => '▶',
            sign_hl   => 'XSDebugPC',
            hl_group  => 'XSDebugPCLine',
            priority  => 70,
        };
        if ($buf->can('set_extmark')) {
            eval { $buf->set_extmark($ns, $pc_line - 1, 0, $mark) };
        }
        elsif ($core_buf->can('set_extmark')) {
            eval { $core_buf->set_extmark($ns, $pc_line - 1, 0, $mark) };
        }
        $count++;
    }
    return $count;
}

# -------------------------------------------------------------------------
# 2. Full GDB/MI (mi3) Recursive-Descent Parser
# -------------------------------------------------------------------------

sub _mi_parse_string {
    my ($s, $pos_ref) = @_;
    $$pos_ref++;    # skip opening "
    my $out = '';
    my $len = length($s);
    while ($$pos_ref < $len) {
        my $ch = substr($s, $$pos_ref, 1);
        $$pos_ref++;
        if ($ch eq '"') {
            return $out;
        }
        elsif ($ch eq '\\' && $$pos_ref < $len) {
            my $esc = substr($s, $$pos_ref, 1);
            $$pos_ref++;
            if    ($esc eq 'n')  { $out .= "\n" }
            elsif ($esc eq 't')  { $out .= "\t" }
            elsif ($esc eq 'r')  { $out .= "\r" }
            elsif ($esc eq '"')  { $out .= '"'  }
            elsif ($esc eq '\\') { $out .= '\\' }
            else                 { $out .= $esc }
        }
        else {
            $out .= $ch;
        }
    }
    return $out;
}

sub _mi_parse_value {
    my ($s, $pos_ref) = @_;
    my $len = length($s);
    return '' if $$pos_ref >= $len;
    my $ch = substr($s, $$pos_ref, 1);

    if ($ch eq '"') {
        return _mi_parse_string($s, $pos_ref);
    }
    elsif ($ch eq '{') {
        $$pos_ref++;
        my %h;
        while ($$pos_ref < $len) {
            my $c = substr($s, $$pos_ref, 1);
            if ($c eq '}') { $$pos_ref++; last; }
            if ($c eq ',') { $$pos_ref++; next; }
            if (substr($s, $$pos_ref) =~ /\A([A-Za-z0-9_-]+)=/) {
                my $k = $1;
                $$pos_ref += length($k) + 1;
                my $v = _mi_parse_value($s, $pos_ref);
                if (exists $h{$k}) {
                    $h{$k} = [ $h{$k} ] unless ref($h{$k}) eq 'ARRAY';
                    push @{ $h{$k} }, $v;
                }
                else {
                    $h{$k} = $v;
                }
            }
            else {
                $$pos_ref++;
            }
        }
        return \%h;
    }
    elsif ($ch eq '[') {
        $$pos_ref++;
        my @arr;
        while ($$pos_ref < $len) {
            my $c = substr($s, $$pos_ref, 1);
            if ($c eq ']') { $$pos_ref++; last; }
            if ($c eq ',') { $$pos_ref++; next; }
            # List elements can be bare values OR key=value pairs (e.g. stack=[frame={...},frame={...}])
            if ($c ne '"' && $c ne '{' && $c ne '[' && substr($s, $$pos_ref) =~ /\A([A-Za-z0-9_-]+)=/) {
                my $k = $1;
                $$pos_ref += length($k) + 1;
                my $v = _mi_parse_value($s, $pos_ref);
                push @arr, (ref($v) eq 'HASH' ? { _tag => $k, %$v } : { $k => $v });
            }
            else {
                push @arr, _mi_parse_value($s, $pos_ref);
            }
        }
        return \@arr;
    }

    # Unquoted fallback token
    if (substr($s, $$pos_ref) =~ /\A([^,}\]]+)/) {
        $$pos_ref += length($1);
        return $1;
    }
    return '';
}

sub parse_mi_record {
    my ($self, $line) = @_;
    return undef unless defined $line;
    $line =~ s/\r?\n\z//;
    return undef if $line eq '' || $line eq '(gdb)';

    my $token;
    if ($line =~ s/^(\d+)//) {
        $token = $1 + 0;
    }

    my $prefix = substr($line, 0, 1);
    my $rest   = substr($line, 1);

    # Stream records: ~"console", @"target", &"log"
    if ($prefix eq '~' || $prefix eq '@' || $prefix eq '&') {
        my $pos = 0;
        my $text = substr($rest, 0, 1) eq '"' ? _mi_parse_string($rest, \$pos) : $rest;
        my %stype = ('~' => 'console', '@' => 'target', '&' => 'log');
        return {
            token => $token,
            type  => 'stream',
            class => $stype{$prefix},
            text  => $text,
        };
    }

    # Result (^), Exec (*), Status (+), Notify (=)
    my %rtype = ('^' => 'result', '*' => 'exec', '+' => 'status', '=' => 'notify');
    return { type => 'raw', text => $line } unless exists $rtype{$prefix};

    my ($class, $body) = split /,/, $rest, 2;
    my %data;
    if (defined $body && length $body) {
        my $pos = 0;
        my $len = length($body);
        while ($pos < $len) {
            my $c = substr($body, $pos, 1);
            if ($c eq ',') { $pos++; next; }
            if (substr($body, $pos) =~ /\A([A-Za-z0-9_-]+)=/) {
                my $k = $1;
                $pos += length($k) + 1;
                $data{$k} = _mi_parse_value($body, \$pos);
            }
            else {
                last;
            }
        }
    }

    return {
        token => $token,
        type  => $rtype{$prefix},
        class => $class,
        data  => \%data,
    };
}

sub _map_loc {
    my ($self, $file, $line) = @_;
    if ($self->{runner} && defined $file && defined $line) {
        return $self->{runner}->map_location($file, $line);
    }
    return {
        file      => $file,
        line      => defined($line) ? ($line + 0) : undef,
        orig_file => $file,
        orig_line => defined($line) ? ($line + 0) : undef,
        mapped    => 0,
    };
}

sub parse_mi_stack {
    my ($self, $mi_line) = @_;
    my $rec = ref($mi_line) eq 'HASH' ? $mi_line : $self->parse_mi_record($mi_line);
    return [] unless $rec && ref($rec->{data}) eq 'HASH' && ref($rec->{data}{stack}) eq 'ARRAY';

    my @frames;
    for my $f (@{ $rec->{data}{stack} }) {
        next unless ref($f) eq 'HASH';
        my $file = $f->{fullname} || $f->{file};
        my $line = defined $f->{line} ? ($f->{line} + 0) : undef;
        my $loc  = defined($file) && defined($line) ? $self->_map_loc($file, $line) : { file => $file, line => $line };
        push @frames, {
            level     => ($f->{level} || 0) + 0,
            addr      => $f->{addr},
            func      => $f->{func} || '??',
            file      => $loc->{file},
            line      => $loc->{line},
            orig_file => $loc->{orig_file},
            orig_line => $loc->{orig_line},
            mapped_xs => $loc->{mapped} || 0,
        };
    }
    return \@frames;
}

sub parse_mi_locals {
    my ($self, $mi_line) = @_;
    my $rec = ref($mi_line) eq 'HASH' ? $mi_line : $self->parse_mi_record($mi_line);
    return [] unless $rec && ref($rec->{data}) eq 'HASH';
    my $list = $rec->{data}{locals} || $rec->{data}{variables} || [];
    return [] unless ref($list) eq 'ARRAY';

    my @locals;
    for my $v (@$list) {
        next unless ref($v) eq 'HASH';
        push @locals, {
            name  => $v->{name}  // '',
            type  => $v->{type}  // '',
            value => $v->{value} // '',
            is_sv => (($v->{type} || '') =~ /\b(?:SV|AV|HV|CV|GV)\s*\*/ ? 1 : 0),
        };
    }
    return \@locals;
}

sub parse_mi_threads {
    my ($self, $mi_line) = @_;
    my $rec = ref($mi_line) eq 'HASH' ? $mi_line : $self->parse_mi_record($mi_line);
    return [] unless $rec && ref($rec->{data}) eq 'HASH' && ref($rec->{data}{threads}) eq 'ARRAY';
    my $cur_id = $rec->{data}{'current-thread-id'};

    my @threads;
    for my $t (@{ $rec->{data}{threads} }) {
        next unless ref($t) eq 'HASH';
        my $frame = ref($t->{frame}) eq 'HASH' ? $t->{frame} : {};
        my $func  = $frame->{func} || '';
        push @threads, {
            id          => $t->{id},
            target_id   => $t->{'target-id'} || '',
            state       => $t->{state} || '',
            current     => (defined $cur_id && $t->{id} eq $cur_id) ? 1 : 0,
            func        => $func,
            file        => $frame->{fullname} || $frame->{file},
            line        => defined($frame->{line}) ? ($frame->{line} + 0) : undef,
            is_my_perl  => ($func =~ /(?:mt_worker|Perl_|XS_|S_runops)/i ? 1 : 0),
        };
    }
    return \@threads;
}

sub categorize_power_registers {
    my ($self, $reg_map) = @_;
    my %power = (gpr => {}, vsx => {}, spr => {});
    return \%power unless ref($reg_map) eq 'HASH';

    for my $name (keys %$reg_map) {
        my $val = $reg_map->{$name};
        my $lc  = lc($name);
        if ($lc =~ /^r([0-9]|[12][0-9]|3[01])$/) {
            $power{gpr}{$lc} = $val;
        }
        elsif ($lc =~ /^vs([0-9]|[1-5][0-9]|6[0-3])$/ || $lc =~ /^vr?([0-9]|[12][0-9]|3[01])$/) {
            $power{vsx}{$lc} = $val;
        }
        elsif ($lc =~ /^(?:pc|nip|msr|cr|lr|ctr|xer|orig_r3|trap|fpscr|vscr|vrsave)$/) {
            $power{spr}{ uc($lc) } = $val;
        }
    }
    return \%power;
}

sub parse_mi_registers {
    my ($self, $names_rec, $values_rec) = @_;
    my $nrec = ref($names_rec)  eq 'HASH' ? $names_rec  : $self->parse_mi_record($names_rec);
    my $vrec = ref($values_rec) eq 'HASH' ? $values_rec : $self->parse_mi_record($values_rec);

    my $names  = ($nrec && ref($nrec->{data}) eq 'HASH') ? ($nrec->{data}{'register-names'}  || []) : [];
    my $values = ($vrec && ref($vrec->{data}) eq 'HASH') ? ($vrec->{data}{'register-values'} || []) : [];

    my %regs;
    for my $v (@$values) {
        next unless ref($v) eq 'HASH' && defined $v->{number};
        my $idx  = $v->{number} + 0;
        my $name = $names->[$idx];
        next unless defined $name && length $name;
        $regs{$name} = $v->{value};
    }
    return {
        all   => \%regs,
        power => $self->categorize_power_registers(\%regs),
    };
}

# -------------------------------------------------------------------------
# 3. LLDB Output Parsers (macOS + Linux LLDB)
# -------------------------------------------------------------------------

sub parse_lldb_backtrace {
    my ($self, $text) = @_;
    $text = '' unless defined $text;
    my @frames;

    for my $raw (split /\n/, $text) {
        $raw =~ s/\r\z//;
        #   * frame #0: 0x00000001000004bc lldb_t`compute(x=19, y=23) at lldb_t.c:3:15
        #     frame #2: 0x000000019d294d7c dyld`start + 6652
        if ($raw =~ /^\s*\*?\s*frame\s+#(\d+):\s+(0x[0-9a-fA-F]+)\s+(?:([^`\s]+)`([^\s(]+(?:\([^)]*\))?)|(\S+))(?:\s+\+\s+\d+)?(?:\s+at\s+([^:\s]+):(\d+)(?::(\d+))?)?/) {
            my ($lvl, $addr, $mod, $fn, $alt_fn, $f, $ln, $col) = ($1 + 0, $2, $3, $4, $5, $6, $7, $8);
            my $func = defined $fn ? $fn : ($alt_fn // '??');
            $func =~ s/\(.*\)\z//;
            my $loc = (defined $f && defined $ln) ? $self->_map_loc($f, $ln) : { file => $f, line => undef };
            push @frames, {
                level     => $lvl,
                addr      => $addr,
                module    => $mod,
                func      => $func,
                file      => $loc->{file},
                line      => $loc->{line},
                col       => defined($col) ? ($col + 0) : 1,
                orig_file => $loc->{orig_file},
                orig_line => $loc->{orig_line},
                mapped_xs => $loc->{mapped} || 0,
            };
        }
    }
    return \@frames;
}

sub parse_lldb_locals {
    my ($self, $text) = @_;
    $text = '' unless defined $text;
    my @locals;
    for my $raw (split /\n/, $text) {
        $raw =~ s/\r\z//;
        if ($raw =~ /^\s*\(([^)]+)\)\s+([A-Za-z_]\w*)\s*=\s*(.+)$/) {
            my ($type, $name, $val) = ($1, $2, $3);
            push @locals, {
                type  => $type,
                name  => $name,
                value => $val,
                is_sv => ($type =~ /\b(?:SV|AV|HV|CV|GV)\s*\*/ ? 1 : 0),
            };
        }
    }
    return \@locals;
}

sub parse_lldb_threads {
    my ($self, $text) = @_;
    $text = '' unless defined $text;
    my @threads;
    for my $raw (split /\n/, $text) {
        $raw =~ s/\r\z//;
        if ($raw =~ /^(\*)?\s*thread\s+#(\d+):\s+tid\s*=\s*(\S+),?\s*(.*)$/) {
            my ($cur, $id, $tid, $rest) = (defined $1 ? 1 : 0, $2, $3, $4);
            $tid =~ s/,$//;
            my $func = '';
            $func = $1 if $rest =~ /`([^\s(+]+)/;
            my $stop = '';
            $stop = $1 if $rest =~ /stop reason\s*=\s*(.+)$/;
            push @threads, {
                id         => $id,
                target_id  => $tid,
                current    => $cur,
                func       => $func,
                state      => $stop || 'stopped',
                is_my_perl => ($func =~ /(?:mt_worker|Perl_|XS_|S_runops)/i ? 1 : 0),
            };
        }
    }
    return \@threads;
}

sub parse_lldb_registers {
    my ($self, $text) = @_;
    $text = '' unless defined $text;
    my %regs;
    for my $raw (split /\n/, $text) {
        $raw =~ s/\r\z//;
        if ($raw =~ /^\s*([A-Za-z0-9_]+)\s*=\s*(0x[0-9a-fA-F]+|\{[^}]+\})/) {
            $regs{$1} = $2;
        }
    }
    return {
        all   => \%regs,
        power => $self->categorize_power_registers(\%regs),
    };
}

# -------------------------------------------------------------------------
# 4. Perl SV* / AV* / HV* Inspector (Perl_sv_dump parser)
# -------------------------------------------------------------------------

sub parse_sv_dump {
    my ($self, $text, %opts) = @_;
    $text = '' unless defined $text;
    my %sv = (
        expr   => $opts{expr},
        raw    => $text,
        type   => undef,
        addr   => undef,
        refcnt => undef,
        flags  => [],
        iv     => undef,
        uv     => undef,
        nv     => undef,
        pv     => undef,
        cur    => undef,
        len    => undef,
        av_fill => undef,
        av_max  => undef,
        hv_keys => undef,
        hv_max  => undef,
    );

    for my $line (split /\n/, $text) {
        if ($line =~ /SV\s*=\s*([A-Z0-9_]+)\((0x[0-9a-fA-F]+)\)\s+at\s+(0x[0-9a-fA-F]+)/) {
            $sv{type}      = $1;
            $sv{body_addr} = $2;
            $sv{addr}      = $3;
        }
        elsif ($line =~ /SV\s*=\s*([A-Z0-9_]+)\s+at\s+(0x[0-9a-fA-F]+)/) {
            $sv{type} = $1;
            $sv{addr} = $2;
        }
        $sv{refcnt}  = $1 + 0 if $line =~ /\bREFCNT\s*=\s*(\d+)/;
        $sv{flags}   = [ split /,\s*/, $1 ] if $line =~ /\bFLAGS\s*=\s*\(([^)]*)\)/;
        $sv{iv}      = $1 + 0 if $line =~ /^\s*IV\s*=\s*(-?\d+)/;
        $sv{uv}      = $1 + 0 if $line =~ /^\s*UV\s*=\s*(\d+)/;
        $sv{nv}      = $1 + 0 if $line =~ /^\s*NV\s*=\s*([-+0-9.eE]+)/;
        $sv{pv}      = $1     if $line =~ /^\s*PV\s*=\s*0x[0-9a-fA-F]+\s+"((?:\\.|[^"])*)"/;
        $sv{cur}     = $1 + 0 if $line =~ /^\s*CUR\s*=\s*(\d+)/;
        $sv{len}     = $1 + 0 if $line =~ /^\s*LEN\s*=\s*(\d+)/;
        $sv{av_fill} = $1 + 0 if $line =~ /^\s*FILL\s*=\s*(-?\d+)/;
        $sv{av_max}  = $1 + 0 if $line =~ /^\s*MAX\s*=\s*(-?\d+)/ && ($sv{type} || '') =~ /AV/;
        $sv{hv_keys} = $1 + 0 if $line =~ /^\s*KEYS\s*=\s*(\d+)/;
        $sv{hv_max}  = $1 + 0 if $line =~ /^\s*MAX\s*=\s*(\d+)/  && ($sv{type} || '') =~ /HV/;
    }

    return \%sv;
}

# -------------------------------------------------------------------------
# 5. Live Batch Backtrace & State Capture (LLDB on macOS, GDB/MI3 on Linux)
# -------------------------------------------------------------------------

sub capture_backtrace {
    my ($self, $binary, %opts) = @_;
    my $runner = $self->{runner} or return { ok => 0, error => 'no Runner configured' };
    my $tools  = $runner->detect_tools(remote => $opts{remote});

    my $backend = $opts{backend};
    if (!$backend) {
        $backend = $tools->{is_macos}
            ? ($tools->{lldb} ? 'lldb' : ($tools->{gdb} ? 'gdb' : undef))
            : ($tools->{gdb}  ? 'gdb'  : ($tools->{lldb} ? 'lldb' : undef));
    }
    return { ok => 0, error => 'neither gdb nor lldb found on target host' } unless $backend;

    if ($backend eq 'lldb') {
        return $self->_capture_lldb($binary, $tools, %opts);
    }
    return $self->_capture_gdb_mi($binary, $tools, %opts);
}

sub _capture_lldb {
    my ($self, $binary, $tools, %opts) = @_;
    my @cmd = ($tools->{lldb}, '--batch');

    if (defined $opts{break_func} && length $opts{break_func}) {
        push @cmd, '-o', "breakpoint set -n $opts{break_func}";
    }
    elsif (defined $opts{break_file} && defined $opts{break_line}) {
        push @cmd, '-o', "breakpoint set --file $opts{break_file} --line $opts{break_line}";
    }
    else {
        for my $bp (@{ $self->list_breakpoints }) {
            push @cmd, '-o', "breakpoint set --file $bp->{file} --line $bp->{line}";
        }
    }

    my $run_cmd = 'run';
    if (ref($opts{args}) eq 'ARRAY' && @{ $opts{args} }) {
        $run_cmd .= ' ' . join(' ', @{ $opts{args} });
    }
    push @cmd,
        '-o', $run_cmd,
        '-o', 'bt',
        '-o', 'frame variable',
        '-o', 'thread list',
        '-o', 'register read',
        '-o', 'quit',
        '--', $binary;

    my $res = $self->{runner}->run_cmd(\@cmd, remote => $opts{remote}, timeout => $opts{timeout} || 45);
    my $out = ($res->{stdout} // '') . "\n" . ($res->{stderr} // '');

    my $bt      = $self->parse_lldb_backtrace($out);
    my $locals  = $self->parse_lldb_locals($out);
    my $threads = $self->parse_lldb_threads($out);
    my $regs    = $self->parse_lldb_registers($out);

    $self->{backend} = 'lldb';
    $self->{state} = {
        active          => 1,
        backend         => 'lldb',
        target          => $binary,
        pc_file         => (@$bt ? $bt->[0]{file} : undef),
        pc_line         => (@$bt ? $bt->[0]{line} : undef),
        stop_reason     => (@$threads ? $threads->[0]{state} : 'stopped'),
        backtrace       => $bt,
        locals          => $locals,
        threads         => $threads,
        registers       => $regs->{all},
        power_registers => $regs->{power},
        sv_inspector    => $self->{state}{sv_inspector} || [],
    };

    return {
        ok              => (@$bt > 0 ? 1 : 0),
        backend         => 'lldb',
        target          => $binary,
        backtrace       => $bt,
        locals          => $locals,
        threads         => $threads,
        registers       => $regs->{all},
        power_registers => $regs->{power},
        raw_output      => $out,
        elapsed_ms      => $res->{elapsed_ms},
    };
}

sub _build_gdb_batch_cmd {
    my ($self, $gdb_bin, $binary, $mi_interp, %opts) = @_;
    my @cmd = ($gdb_bin, '--nx', '--batch', '--quiet');

    if (defined $opts{break_func} && length $opts{break_func}) {
        push @cmd, '-ex', "break $opts{break_func}";
    }
    elsif (defined $opts{break_file} && defined $opts{break_line}) {
        push @cmd, '-ex', "break $opts{break_file}:$opts{break_line}";
    }
    else {
        for my $bp (@{ $self->list_breakpoints }) {
            push @cmd, '-ex', "break $bp->{file}:$bp->{line}";
        }
    }

    if (ref($opts{args}) eq 'ARRAY' && @{ $opts{args} }) {
        push @cmd, '-ex', 'set args ' . join(' ', @{ $opts{args} });
    }

    # GNU GDB -ex always executes CLI commands; use CLI run (synchronous in --batch)
    # followed by interpreter-exec mi3 (or mi fallback) for structured MI3 records.
    push @cmd,
        '-ex', 'run',
        '-ex', qq{interpreter-exec $mi_interp "101-stack-list-frames"},
        '-ex', qq{interpreter-exec $mi_interp "102-stack-list-variables --all-values"},
        '-ex', qq{interpreter-exec $mi_interp "103-thread-info"},
        '-ex', qq{interpreter-exec $mi_interp "104-data-list-register-names"},
        '-ex', qq{interpreter-exec $mi_interp "105-data-list-register-values x"},
        $binary;

    return \@cmd;
}

sub _capture_gdb_mi {
    my ($self, $binary, $tools, %opts) = @_;
    my $cmd = $self->_build_gdb_batch_cmd($tools->{gdb}, $binary, 'mi3', %opts);
    my $res = $self->{runner}->run_cmd($cmd, remote => $opts{remote}, timeout => $opts{timeout} || 45);
    my $out = ($res->{stdout} // '') . "\n" . ($res->{stderr} // '');

    # Older GDB (< 9) may lack mi3; fall back cleanly to generic 'mi'
    if ($out =~ /Interpreter\s+['"]?mi3['"]?\s+unrecognized/i) {
        $cmd = $self->_build_gdb_batch_cmd($tools->{gdb}, $binary, 'mi', %opts);
        $res = $self->{runner}->run_cmd($cmd, remote => $opts{remote}, timeout => $opts{timeout} || 45);
        $out = ($res->{stdout} // '') . "\n" . ($res->{stderr} // '');
    }

    my ($bt, $locals, $threads, $rnames, $rvals) = ([], [], [], undef, undef);
    for my $line (split /\n/, $out) {
        my $rec = $self->parse_mi_record($line) or next;
        next unless ($rec->{type} || '') eq 'result' && ($rec->{class} || '') eq 'done';
        my $tok = $rec->{token} || 0;
        if ($tok == 101 || exists $rec->{data}{stack}) {
            $bt = $self->parse_mi_stack($rec);
        }
        elsif ($tok == 102 || exists $rec->{data}{variables} || exists $rec->{data}{locals}) {
            $locals = $self->parse_mi_locals($rec);
        }
        elsif ($tok == 103 || exists $rec->{data}{threads}) {
            $threads = $self->parse_mi_threads($rec);
        }
        elsif ($tok == 104 || exists $rec->{data}{'register-names'}) {
            $rnames = $rec;
        }
        elsif ($tok == 105 || exists $rec->{data}{'register-values'}) {
            $rvals = $rec;
        }
    }

    my $regs = ($rnames && $rvals)
        ? $self->parse_mi_registers($rnames, $rvals)
        : { all => {}, power => { gpr => {}, vsx => {}, spr => {} } };

    $self->{backend} = 'gdb';
    $self->{state} = {
        active          => 1,
        backend         => 'gdb',
        target          => $binary,
        pc_file         => (@$bt ? $bt->[0]{file} : undef),
        pc_line         => (@$bt ? $bt->[0]{line} : undef),
        stop_reason     => 'breakpoint-hit',
        backtrace       => $bt,
        locals          => $locals,
        threads         => $threads,
        registers       => $regs->{all},
        power_registers => $regs->{power},
        sv_inspector    => $self->{state}{sv_inspector} || [],
    };

    return {
        ok              => (@$bt > 0 ? 1 : 0),
        backend         => 'gdb',
        target          => $binary,
        backtrace       => $bt,
        locals          => $locals,
        threads         => $threads,
        registers       => $regs->{all},
        power_registers => $regs->{power},
        raw_output      => $out,
        elapsed_ms      => $res->{elapsed_ms},
    };
}

# -------------------------------------------------------------------------
# 6. Interactive Session Controls (GDB/MI3 & LLDB stepping / SV* inspect)
# -------------------------------------------------------------------------

sub start_session {
    my ($self, $binary, %opts) = @_;
    $self->stop_session();
    my $runner = $self->{runner} or return { ok => 0, error => 'no Runner configured' };
    my $tools  = $runner->detect_tools(remote => $opts{remote});

    my $backend = $opts{backend} || $tools->{preferred_debugger};
    return { ok => 0, error => 'no debugger available' } unless $backend;
    $backend = ($backend =~ /gdb/i) ? 'gdb' : 'lldb';

    my @cmd;
    if ($backend eq 'gdb') {
        @cmd = ($tools->{gdb} || 'gdb', '--nx', '--quiet', '--interpreter=mi3', $binary);
    }
    else {
        @cmd = ($tools->{lldb} || 'lldb', '--no-lldbinit', $binary);
    }

    my ($out, $in);
    my $pid = eval { IPC::Open2::open2($out, $in, @cmd) };
    return { ok => 0, error => "failed to start $backend: $@" } unless $pid;

    select((select($in), $| = 1)[0]);
    $self->{backend}       = $backend;
    $self->{session_pid}   = $pid;
    $self->{session_in}    = $in;
    $self->{session_out}   = $out;
    $self->{state}{active}  = 1;
    $self->{state}{backend} = $backend;
    $self->{state}{target}  = $binary;

    # Replay saved breakpoints
    for my $bp (@{ $self->list_breakpoints }) {
        if ($backend eq 'gdb') {
            $self->_send_session("-break-insert \"$bp->{file}\":$bp->{line}\n");
        }
        else {
            $self->_send_session("breakpoint set --file $bp->{file} --line $bp->{line}\n");
        }
    }

    return { ok => 1, backend => $backend, pid => $pid };
}

sub _send_session {
    my ($self, $cmd) = @_;
    return 0 unless $self->{session_in};
    print { $self->{session_in} } $cmd;
    return 1;
}

sub step_over    { my ($s) = @_; $s->_send_session(($s->{backend} || '') eq 'gdb' ? "-exec-next\n"     : "next\n") }
sub step_into    { my ($s) = @_; $s->_send_session(($s->{backend} || '') eq 'gdb' ? "-exec-step\n"     : "step\n") }
sub step_out     { my ($s) = @_; $s->_send_session(($s->{backend} || '') eq 'gdb' ? "-exec-finish\n"   : "finish\n") }
sub continue_run { my ($s) = @_; $s->_send_session(($s->{backend} || '') eq 'gdb' ? "-exec-continue\n" : "continue\n") }

sub inspect_sv {
    my ($self, $expr, %opts) = @_;
    $expr ||= 'sv';
    if (defined $opts{dump_text}) {
        my $parsed = $self->parse_sv_dump($opts{dump_text}, expr => $expr);
        push @{ $self->{state}{sv_inspector} }, $parsed;
        return $parsed;
    }
    if ($self->{session_in}) {
        my $call = ($self->{backend} || '') eq 'gdb'
            ? "-data-evaluate-expression \"Perl_sv_dump(my_perl, (SV*)($expr))\"\n"
            : "expr -- (void)Perl_sv_dump(my_perl, (SV*)($expr))\n";
        $self->_send_session($call);
        return { ok => 1, dispatched => 1, expr => $expr };
    }
    return { ok => 0, error => 'no active debugger session', expr => $expr };
}

sub stop_session {
    my ($self) = @_;
    if ($self->{session_pid}) {
        eval {
            $self->_send_session(($self->{backend} || '') eq 'gdb' ? "-gdb-exit\n" : "quit\n");
            close $self->{session_in}  if $self->{session_in};
            close $self->{session_out} if $self->{session_out};
            kill 'TERM', $self->{session_pid};
            waitpid($self->{session_pid}, 0);
        };
    }
    $self->{session_pid}    = undef;
    $self->{session_in}     = undef;
    $self->{session_out}    = undef;
    $self->{state}{active}  = 0;
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    $self->stop_session();
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::XSDev::Debugger - Interactive GDB/MI3 and LLDB XS debugger

=head1 SYNOPSIS

    use NeoPerl::Plugin::XSDev::Debugger;

    my $dbg = NeoPerl::Plugin::XSDev::Debugger->new(runner => $runner);
    my $bt  = $dbg->capture_backtrace('./my_prog', break_func => 'compute');

=head1 DESCRIPTION

Drives C<gdb --interpreter=mi3> (Linux x86_64/ppc64le and SSH) and C<lldb>
(macOS) with full MI3 tuple/list parsing, gutter breakpoints and current-PC
extmarks in namespace C<xs_debug>, Backtrace, Locals, Watch, C<perl5-mt>
C<my_perl> thread tagging, IBM POWER register categorization (C<r0>-C<r31>,
C<vs0>-C<vs63>, C<CR>, C<LR>, C<CTR>), and Perl C<SV*>/C<AV*>/C<HV*>
C<Perl_sv_dump> parsing.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
