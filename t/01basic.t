use Test;
BEGIN { plan tests => 2 }
END { ok(0) unless $loaded }
use XML::LibXSLT;
$loaded = 1;
ok(1);

my $p = XML::LibXSLT->new();
ok($p);
