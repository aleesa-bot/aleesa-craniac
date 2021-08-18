package Craniac;

# общие модули - синтаксис, кодировки итд
use 5.018;
use strict;
use warnings;
use utf8;
use open qw (:std :utf8);

# модули для работы приложения
use Digest::SHA qw (sha1_base64);
use JSON::XS;
use Hailo;
use Log::Any qw ($log);
use Mojo::Redis;
use Mojo::IOLoop;
use Math::Random::Secure qw (irand);
use Text::Fuzzy qw (distance_edits);

use version; our $VERSION = qw (1.0);
use Exporter qw (import);
our @EXPORT_OK = qw (RunCraniac);

sub LoadConf ();
sub RandomCommonPhrase ();
sub utf2sha1 ($);
sub fmatch (@);
sub RunCraniac ();

my $c = LoadConf ();
my $hailo;

sub LoadConf {
	my $cfg = 'data/config.json';
	open my $CH, '<', $c or die "[FATAL] No conf at $c: $OS_ERROR\n";
	my $len = (stat $cfg) [7];
	my $json;
	my $readlen = read $CH, $json, $len;

	unless ($readlen) {
		close $CH;                                   ## no critic (InputOutput::RequireCheckedSyscalls
		die "[FATAL] Unable to read $c: $OS_ERROR\n";
	}

	if ($readlen != $len) {
		close $CH;                                   ## no critic (InputOutput::RequireCheckedSyscalls
		die "[FATAL] File $c is $len bytes on disk, but we read only $readlen bytes\n";
	}

	close $CH;                                       ## no critic (InputOutput::RequireCheckedSyscalls
	my $j = JSON::XS->new->utf8->relaxed;
	return $j->decode ($json);
}

sub RandomCommonPhrase () {
	my @myphrase = (
		'Так, блядь...',
		'*Закатывает рукава* И ради этого ты меня позвал?',
		'Ну чего ты начинаешь, нормально же общались',
		'Повтори свой вопрос, не поняла',
		'Выйди и зайди нормально',
		'Я подумаю',
		'Даже не знаю что на это ответить',
		'Ты упал такие вопросы девочке задавать?',
		'Можно и так, но не уверена',
		'А как ты думаешь?',
	);

	return $myphrase[irand ($#myphrase + 1)];
}

sub utf2sha1 () {
	my $string = shift;

	if ($string eq '') {
		return sha1_base64 '';
	}

	my $bytes = encode_utf8 $string;
	return sha1_base64 $bytes;
}

sub fmatch (@) {
	my $srcphrase = shift;
	my $answer = shift;

	my ($distance, undef) = distance_edits ($srcphrase, $answer);
	my $srcphraselen = length $srcphrase;
	my $distance_max = int ($srcphraselen - ($srcphraselen * (100 - (90 / ($srcphraselen ** 0.5))) * 0.01));

	if ($distance >= $distance_max) {
		return 0;
	} else {
		return 1;
	}
}

# основной парсер
my $parse_message = sub {
	my $self = shift;
	my $m = shift;
	my $answer = $m;
	my $send_to = $answer->{from};
	my $chatid = $m->{chatid};

	unless (defined $hailo->{$chatid}) {
		my $cid = $chatid;

		# костыль, чтобы не портировать данные из телеграммных мозгов
		unless ($m->{from} eq 'telegram') {
			$cid = utf2sha1 ($chatid);
			$cid =~ s/\//-/xmsg;
		}

		my $brainname = sprintf '%s/%s.sqlite', $c->{braindir}, $cid;

		$hailo->{$chatid} = Hailo->new (
			brain => $brainname,
			order => 3
		);

		unless (defined $hailo->{$chatid}) {
			$log->warn ($EVAL_ERROR);
			return;
		}

		$log->info (sprintf 'Lazy init brain: %s', $brainname);
	}

	if ($m->{misc}->{answer}) {

		# пытаемся что-то генерировать, если фраза длиннее 3-х букв
		if (length ($m->{message}) > 3) {
			$answer->{message} = $hailo->{$chatid}->learn_reply ($m->{message});

			# если из реактора вернулся undef выдаём "общую" фразу из словаря
			unless (defined $answer->{message}) {
				$answer->{message} = RandomCommonPhrase ();
			}

			# если из реактора вернулась пустота выдаём "общую" фразу из словаря
			if ($answer->{message} eq '') {
				$answer->{message} = RandomCommonPhrase ();
			}

			# если сгенерированная фраза слишком похожа на начальную - выдаём "общую" фразу из словаря
			if (fmatch (lc ($m->{message}), lc($answer->{message}))) {
				$answer->{message} = RandomCommonPhrase ();
			}

			$self->json ($send_to)->notify (
				$send_to => {
					from    => $answer->{from},
					userid  => $answer->{userid},
					chatid  => $answer->{chatid},
					plugin  => $answer->{plugin},
					message => $answer->{message}
				}
			);
		}
	} else {

		# пытаемся что-то запоминать, если фраза длиннее 3-х букв
		if (length ($m->{message}) > 3) {
			$hailo->{$chatid}->learn ($m->{message});
		}
	}

	return;
};

# main loop, он же event loop
sub RunCraniac {
	my $redis = Mojo::Redis->new (
		sprintf 'redis://%s:%s/1', $c->{server}, $c->{port}
	);

	my $pubsub = $redis->pubsub;
	my $sub;

	$pubsub->listen (
		# Вот такая ебическая конструкция для авто-подписывания на все новые каналы.
		# Странное ограничение, при котором на шаблон каналов можно подписаться только, подписавшись на каждый из
		# каналов. То есть подписка создаётся по запросу. В AnyEvent::Redis подписаться можно сразу на * :(
		# Но конкретно в моём случае этот момент неважен, т.к. подразумевается, что каналы будут добавляться, но не 
		# будут убавляться.
		'craniac:*' => sub {
			my ($ps, $channel) = @_ ;

			unless (defined $sub->{$channel}) {
				$log->info ("Subscribing to $channel");

				$sub->{$channel} = $ps->json ($channel)->listen (
					$channel => sub { $parse_message->(@_); }
				);
			}
		}
	);

	do { Mojo::IOLoop->start } until Mojo::IOLoop->is_running;
	return;
}

1;

# vim: set ft=perl noet ai ts=4 sw=4 sts=4:
