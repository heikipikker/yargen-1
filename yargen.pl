#!/usr/bin/env perl

=license
MIT License
Copyright (c) 2016 Denis Efremov yefremo.denis@gmail.com

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
=cut

use warnings;
use strict;
use feature qw/say/;

use Mojo::UserAgent;
use Storable qw/store retrieve/;
use Getopt::Long;

my $arg_string = join(" ", $0, @ARGV);
my $module;
my $cve;
my $help = 0;

GetOptions("m|module=s" => \$module,
           "c|cve=s"    => \$cve,
           "help"       => \$help)
or die("Error in command line arguments\n");

if ($help) {
	say 'This program was created by Denis Efremov yefremov.denis@gmail.com as a part of competition';
}

die "Please, provide perl module name.\n"
	unless $module;

die "'$module' is not a valid perl module name.\n"
	unless $module =~ /^\w++((?:::)\w++)?$/;

die "Please, provide cve(or other id) argument.\n"
	unless $cve;

if ($cve =~ /^CVE/i) {
   unless ($cve =~ /^CVE-\d{4}-\d{4}$/i) {
      die "'$cve' is not a valid ave id.\n"
   }
}

my $mmodule = 'Perl' . $module =~ s/:++//gr  . 'Module';
my $hmodule = $module =~ s/::/-/gr;
my $ccve = uc($cve =~ tr/-/_/r);

sub trim {
   $_[0] =~ s/(^\s++)|(\s++$)//gr
}

sub to_regex {
   my $v = $_[0];
   $v =~ s!\h+!\\s*!g;
   $v =~ s!([\$\^()\[\]])!\\$1!g;
   $v =~ s!['"]!(\\'|\\")!g;
   $v =~ s!our\\s\K\*!+!g;
   $v;
}

sub retrive_module_versions
{
   my $module = $_[0];
   my $dump = $module . '.dump';
   my @modules;

   if (-f $dump) {
      @modules = @{retrieve($dump)};
   }

   unless (@modules) {
      my $ua = Mojo::UserAgent->new();
      my $r = $ua->get('https://metacpan.org/pod/' . $module);
      if ($r->success && $r->res->code() == 200) {
         my $cl = $r->res->dom
                         ->find('div.release.status-latest.maturity-released select option')
                         ->map(attr => 'value')
                         ->compact()
                         ->map(sub{s!^/module!https://api.metacpan.org/source!r})
                         ->sort()
                         ->uniq();
         @modules = $cl->map(sub {
               my $r = $ua->get($_);
               if ($r->success && $r->res->code() == 200) {
                  $r->res->body
               } else {
                  warn "Can't get module $_\n";
                  undef
               }
            }
         )->compact()->each();
         store \@modules, $dump;
      } else {
         warn "Module not found on metacpan\n";
      }
   }

   my %versions;
   my $ident = 0;
   foreach(@modules) {
      #if (/^.*?v(?:e(?:r(?:s(?:i(?:o(?:n)?)?)?)?)?)?\h*=\h*(?:['"])([^'"]++)(?:['"])\h*;.*$/pim) {
      if (/^.*?v(?:e(?:r(?:s(?:i(?:o(?:n)?)?)?)?)?)?\h*=\h*.*?(\d++(?:[\.\:\-\_]\w++)*).*?;/pim) {
         my $v   = trim(${^MATCH});
         my $ver = 'v_' . $1 =~ tr/./_/r;
         $ident = length($ver)
            if $ident < length($ver);
         unless (exists $versions{$ver}) {
            $versions{$ver} = $v;
         } else {
            die "Different signatures of same version $ver: '$v' and '$versions{$ver}'\n"
               unless $versions{$ver} eq $v;
         }
      } else {
         die "Failed to find version string in module:\n'$_'\n";
      }
   }
   my $str = '';
   foreach(reverse sort keys %versions) {
      my $i = ' ' x ($ident - length($_) + 1);
      my $r = to_regex($versions{$_});
      $str .= "\t\t$_" . $i . "= '$r'\n";
   }

   \$str;
}

sub try_determine_version
{
   if ($_[0] =~ /(?:(?:before|up\h+to)\h*)?(?:\d++(?:[\.\:\-\_]\w++)*)(?:\h*and\h+(?:earlier|bell?ow))?/p) {
      ${^MATCH}
   } else {
      ''
   }
}

sub fetch_description
{
   my $cve = $_[0];
   my %desc;
   my $ua = Mojo::UserAgent->new(max_redirects => 0);
   $ua->transactor->name('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/52.0.2743.116 Safari/537.36');
   
   my $r = $ua->get('http://cve.mitre.org/cgi-bin/cvename.cgi?name=' . $cve);
   if ($r->success && $r->res->code() == 200) {
      my $c = $r->res->dom
              ->find('#GeneratedTable tr:nth-child(4) > td')
              ->map('text')
              ->join("\n");
      $desc{full} = "<p>" . trim($c) . "</p>";
   } else {
      warn "Failed to fetch full description.\n";
      $desc{full} = '';
   }
   
   $r = $ua->post('http://vuldb.com/?search' => form => {cve => $cve});
   if ($r->success && $r->res->code() == 200) {
      my $c = $r->res->dom
                ->find('.vullist')
                ->join("\n");
   
      my @risk  = ($c =~ /risksymbol\h++(\w++)/g);
      if ($#risk == 0) {
         $desc{risk} = $risk[0];
         if ($c =~ /\?id\.\d++\h*"\h*>\h*(.+?)<\/a>/) {
            $desc{short} = $1;
         } else {
            warn "Failed to fetch short description.\n";
            $desc{short} = '';
         }
      } else {
         warn "Failed to fetch risk indicator.\n";
         $desc{risk} = '';
      }
   } else {
      warn "Failed to fetch risk indication and short description.\n";
      $desc{short} = '';
      $desc{risk}  = '';
   }

   $desc{version} = try_determine_version($desc{full});

   \%desc;
}

my $str  = retrive_module_versions($module);
my $desc = fetch_description($cve);

say "#This rule was generated by: $arg_string\n";
my $private_rule_tmpl =
"private rule $mmodule
{
\tmeta:
\t\tcustom_description = \"Private rule for identifying Perl $module Module\"
\tstrings:
\t\t\$package = /package\\s+$module;/
\tcondition:
\t\t\$package
}";
say $private_rule_tmpl;

say '';

my $yara_rule_tmpl =
"rule $ccve
{
\tmeta:
\t\tcomponent_name = \"$hmodule module for Perl\"
\t\tcomponent_version = \"$desc->{version}\"
\t\tcustom_title = \"$desc->{short}\"
\t\tcustom_level = \"$desc->{risk}\"
\t\tcustom_description = \"$desc->{full}\"
\tstrings:
$$str
\tcondition:
\t\t$mmodule and any of (\$v*)
}";
say $yara_rule_tmpl;

