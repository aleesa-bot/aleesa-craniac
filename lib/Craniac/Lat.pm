package Craniac::Lat;
# Крылатые латинские выражения спёрты с https://ru.wikipedia.org/wiki/Список_крылатых_латинских_выражений

use 5.018; ## no critic (ProhibitImplicitImport)
use strict;
use warnings;
use utf8;
use open qw (:std :utf8);
use English qw ( -no_match_vars );
use Carp qw (cluck);
use File::Basename qw (dirname);
use File::Path qw (make_path);
use Hailo ();
use Log::Any qw ($log);

use Conf qw (LoadConf);

use version; our $VERSION = qw (1.0);
use Exporter qw (import);
our @EXPORT_OK = qw (Train Lat);

# В нашем случае среднее количество слов в фразе равно 3, поэтому ставим 2 :)
my $brain_order = 2;

my $c = LoadConf ();
my $brain = $c->{lat}->{brain};
my $srcfile = $c->{lat}->{src};

sub Train () {
	my $braindir = dirname $brain;

	unless (-d $braindir) {
		make_path ($braindir) or do {
			cluck "Unable to create $braindir: $OS_ERROR";
			exit 1;
		};
	}

	my $lat = Hailo->new (
		brain => $brain,
		order => $brain_order,
	);

	$lat->train ($srcfile);
	my ($tokens, $expressions) = ($lat->stats ())[0,1];
	printf "Total tokens: %s\nTotal expressions: %s\n", $tokens, $expressions;
	$lat->save ();
	return;
}

# Просто вернём ответ
sub Lat () {
	my $braindir = dirname $brain;

	unless (-d $braindir) {
		$log->error ("[ERROR] No lat module data: $braindir is absent! Train lat first.");
		return '';
	}

	unless (-e $brain) {
		$log->error ("[ERROR] No lat module data: $brain is absent! Train lat first.");
		return '';
	}

	my $lat = Hailo->new (
		brain => $brain,
		order => $brain_order,
		save_on_exit => 0,
	);

	return $lat->reply ();
}

1;

# vim: ft=perl noet ai ts=4 sw=4 sts=4:
