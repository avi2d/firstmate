#!/usr/bin/env bash
# Usage (sourced, after bin/fm-backend.sh):
#   fm_pane_stale_hash <backend> <harness> <target> <label> <tail40>

fm_pane_hash_digest() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# Herdr trims trailing blanks from every row, so a row as wide as the widest row
# occupies the pane's last column. Pi wraps transcript text one cell short of
# it, so there only the scrollbar and Pi's own full-width rules ever land.
fm_pane_hash_strip_pi_scrollbar() {
  perl -e '
    use strict;
    use warnings;
    use Encode qw(decode encode FB_CROAK LEAVE_SRC);
    binmode STDIN;
    binmode STDOUT;
    local $/;
    my $raw = <STDIN> // "";
    my $text = eval { decode("UTF-8", $raw, FB_CROAK | LEAVE_SRC) };
    if (!defined $text) { print $raw; exit 0; }
    sub cells { my $wide = () = $_[0] =~ /[\p{Ea=W}\p{Ea=F}]/g; length($_[0]) + $wide }
    my @rows = split /\n/, $text, -1;
    my $width = 0;
    for (@rows) { my $c = cells($_); $width = $c if $c > $width; }
    my $stripped = 0;
    for (@rows) {
      next unless /[\x{2502}\x{2503}]\z/ && cells($_) == $width;
      my $body = substr($_, 0, -1);
      if ($body =~ /\A\x{2500}+\z/) { $_ = $body . "\x{2500}"; } else { ($_ = $body) =~ s/ +\z//; }
      $stripped = 1;
    }
    print $stripped ? encode("UTF-8", join("\n", @rows)) : $raw;
  '
}

fm_pane_stale_hash() {  # <backend> <harness> <target> <label> <tail40>
  local viewport
  case "$1:$2" in
    herdr:pi | herdr:pi-signed)
      # A herdr recent read of fullscreen Pi returns a varying number of rows
      # from above the viewport, so the tail differs on an unchanged pane.
      viewport=$(fm_backend_visible_capture "$1" "$3" "$4" 2>/dev/null) || return 1
      printf '%s' "$viewport" | fm_pane_hash_strip_pi_scrollbar | fm_pane_hash_digest
      ;;
    *) printf '%s' "$5" | fm_pane_hash_digest ;;
  esac
}
