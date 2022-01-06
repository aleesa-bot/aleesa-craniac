#!/usr/bin/perl
# Наполняет отдельный "мозг" с бредом латинскими выражениями

use 5.018;
use strict;
use warnings;
use utf8;
use open qw (:std :utf8);
use English qw ( -no_match_vars );
use version; our $VERSION = qw (1.0);

my $workdir;

# До фактического запуска логики программы, сменим рабочий каталог, чтобы подцепить либы
BEGIN {
	use Cwd qw (chdir abs_path);
	my @CWD = split /\//xms, abs_path ($PROGRAM_NAME);
	if ($#CWD > 1) { $#CWD = $#CWD - 2; }
	$workdir = join '/', @CWD;
	chdir $workdir;
}

use lib ("$workdir/lib", "$workdir/vendor_perl", "$workdir/vendor_perl/lib/perl5");
use Craniac::Lat qw (Train);

Train ();
exit 0;
