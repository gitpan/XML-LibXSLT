use strict;
use Test;
BEGIN { plan tests => 26 }
use UNIVERSAL qw(isa);
use XML::LibXSLT;
use XML::LibXML 1.59;
use Data::Dumper;
use Devel::Peek;


my $parser = XML::LibXML->new();
print "# parser\n";
ok($parser);

my $xslt = XML::LibXSLT->new();
print "# xslt\n";
ok($xslt);

my $stylsheetstring = <<'EOT';
<xsl:stylesheet version="1.0"
      xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
      xmlns="http://www.w3.org/1999/xhtml"
      xmlns:exsl="http://exslt.org/common"
      extension-element-prefixes="exsl">

<xsl:template match="/">
<html>
<head><title>Know Your Dromedaries</title></head>
<body>
  <h1><xsl:apply-templates/></h1>
  <xsl:choose>
    <xsl:when test="file">
      <p>foo: <xsl:apply-templates select="document(file)/*" /></p>
    </xsl:when>
    <xsl:when test="write">
      <exsl:document href="{write}">
       <outfile><xsl:value-of select="write"/></outfile>
      </exsl:document>
      <p>wrote: <xsl:value-of select="write"/></p>
    </xsl:when>
    <xsl:otherwise>
     No file given
    </xsl:otherwise>
  </xsl:choose>
</body>
</html>
</xsl:template>

</xsl:stylesheet>
EOT

# We're using input callbacks so that we don't actually need real files while
# testing the security callbacks
my $icb = XML::LibXML::InputCallback->new();
ok($icb);

print "# registering input callbacks\n";
$icb->register_callbacks( [ \&match_cb, \&open_cb,
                            \&read_cb, \&close_cb ] );
$xslt->input_callbacks($icb);


my $scb = XML::LibXSLT::Security->new();
ok($scb);

print "# registering security callbacks\n";
$scb->register_callback( read_file  => \&read_file );
$scb->register_callback( write_file => \&write_file );
$scb->register_callback( create_dir => \&create_dir );
$scb->register_callback( read_net   => \&read_net );
$scb->register_callback( write_net  => \&write_net );
$xslt->security_callbacks($scb);


my $stylesheet = $xslt->parse_stylesheet($parser->parse_string($stylsheetstring));
print "# stylesheet\n";
ok($stylesheet);


# test local read
# ---------------------------------------------------------------------------
# - test allowed
my $doc = $parser->parse_string('<file>allow.xml</file>');
my $results = $stylesheet->transform($doc);
print "# local read results\n";
ok($results);

my $output = $stylesheet->output_string($results);
#warn "output: $output\n";
print "# local read output\n";
ok($output =~ /foo: Text here/);


# - test denied
$doc = $parser->parse_string('<file>deny.xml</file>');
eval {
   $results = $stylesheet->transform($doc);
};
print "# local read denied\n";
ok($@ =~ /read for deny\.xml refused/);



# test local write & create dir
# ---------------------------------------------------------------------------
# - test allowed (no create dir)
my $file = 't/allow.xml';
$doc = $parser->parse_string("<write>$file</write>");
$results = $stylesheet->transform($doc);
print "# local write (no create dir) results\n";
ok($results);

$output = $stylesheet->output_string($results);
#warn "output: $output\n";
print "# local write (no create dir) output\n";
ok($output =~ /wrote: \Q$file\E/);

print "# local write (no create dir) file exists\n";
ok(-s $file);
unlink $file;

# - test allowed (create dir)
$file = 't/newdir/allow.xml';
$doc = $parser->parse_string("<write>$file</write>");
$results = $stylesheet->transform($doc);
print "# local write (create dir) results\n";
ok($results);

$output = $stylesheet->output_string($results);
#warn "output: $output\n";
print "# local write (create dir) output\n";
ok($output =~ /wrote: \Q$file\E/);

print "# local write (create dir) file exists\n";
ok(-s $file);
unlink $file;
rmdir 't/newdir';

# - test denied (no create dir)
$file = 't/deny.xml';
$doc = $parser->parse_string("<write>$file</write>");
eval {
   $results = $stylesheet->transform($doc);
};
print "# local write (no create dir) denied\n";
ok($@ =~ /write for \Q$file\E refused/);
ok(!-e $file);

# - test denied (create dir)
$file = 't/baddir/allow.xml';
$doc = $parser->parse_string("<write>$file</write>");
eval {
   $results = $stylesheet->transform($doc);
};
print "# local write (create dir) denied\n";
ok($@ =~ /creation for \Q$file\E refused/);
ok(!-e $file);


# test net read
# ---------------------------------------------------------------------------
# - test allowed
$doc = $parser->parse_string('<file>http://localhost/allow.xml</file>');
$results = $stylesheet->transform($doc);
print "# net read results\n";
ok($results);

$output = $stylesheet->output_string($results);
#warn "output: $output\n";
print "# net read output\n";
ok($output =~ /foo: Text here/);


# - test denied
$doc = $parser->parse_string('<file>http://localhost/deny.xml</file>');
eval {
   $results = $stylesheet->transform($doc);
};
print "# net read denied\n";
ok($@ =~ m|read for http://localhost/deny\.xml refused|);


# test net write
# ---------------------------------------------------------------------------
# - test allowed
$file = 'http://localhost/allow.xml';
$doc = $parser->parse_string("<write>$file</write>");
eval {
   $results = $stylesheet->transform($doc);
};
print "# net write allowed\n";
ok($@ =~ /unable to save to \Q$file\E/);

# - test denied
$file = 'http://localhost/deny.xml';
$doc = $parser->parse_string("<write>$file</write>");
eval {
   $results = $stylesheet->transform($doc);
};
print "# net write denied\n";
ok($@ =~ /write for \Q$file\E refused/);


# test a dying security callback (and resetting the callback object through
# the stylesheet interface).
# ---------------------------------------------------------------------------
my $scb2 = XML::LibXSLT::Security->new();
$scb2->register_callback( read_file => \&read_file_die );
$stylesheet->security_callbacks($scb2);

# check if transform throws an exception
$doc = $parser->parse_string('<file>allow.xml</file>');
print "# dying callback test\n";
eval {
    $stylesheet->transform($doc);
};
ok($@ =~ /Test die from security callback/);




#
# Security preference callbacks
#
sub read_file {
   my ($tctxt, $value) = @_;
   print "# security read_file: $value\n";
   if ($value eq 'allow.xml') {
      print "# transform context\n";
      ok( isa($tctxt, "XML::LibXSLT::TransformContext") );
      print "# stylesheet from transform context\n";
      ok( isa($tctxt->stylesheet, "XML::LibXSLT::StylesheetWrapper") );
      return 1;
   }
   else {
      return 0;
   }
}

sub read_file_die {
   my ($tctxt, $value) = @_;
   print "# security read_file_die: $value\n";
   die "Test die from security callback";
}

sub write_file {
   my ($tctxt, $value) = @_;
   print "# security write_file: $value\n";
   if ($value =~ /allow\.xml|newdir|baddir/) {
      return 1;
   }
   else {
      return 0;
   }
}

sub create_dir {
   my ($tctxt, $value) = @_;
   print "# security create_dir: $value\n";
   if ($value =~ /newdir/) {
      return 1;
   }
   else {
      return 0;
   }
}

sub read_net {
   my ($tctxt, $value) = @_;
   print "# security read_net: $value\n";
   if ($value =~ /allow\.xml/) {
      return 1;
   }
   else {
      return 0;
   }
}

sub write_net {
   my ($tctxt, $value) = @_;
   print "# security write_net: $value\n";
   if ($value =~ /allow\.xml/) {
      return 1;
   }
   else {
      return 0;
   }
}


#
# input callback functions (used so we don't have to have an actual file)
#
sub match_cb {
    my $uri = shift;
    print "# input match_cb: $uri\n";
    if ($uri =~ /(allow|deny)\.xml/) {
        return 1;
    }
    return 0;
}

sub open_cb {
    my $uri = shift;
    print "# input open_cb: $uri\n";
    my $str ="<foo>Text here</foo>";
    return \$str;
}

sub close_cb {
    print "# input close_cb\n";
}

sub read_cb {
    print "# input read_cb\n";
    return substr(${$_[0]}, 0, $_[1], "");
}