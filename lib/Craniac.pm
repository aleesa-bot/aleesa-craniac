package Craniac;
# Предполагается, что craniac - это "маршрут по-умолчанию". То есть сюда попадают все фразы, которые не были распознаны
# aleesa-misc как команды.

# Основная задача мозгов - распознать, требуется ли ответ и обработать фразу.
# Соответсвенно, мы предполагаем, что фразы делятся на 2 типа:
# * ключевая фраза, на которую у нас есть один или несколько готовых ответов.
# * просто фраза в чате, на которую надо напрячь мозги и (в зависимости от необходимости) ответить на неё или 
#   проигнорировать.

# Общие модули - синтаксис, кодировки итд
use 5.018;
use strict;
use warnings;
use utf8;
use open qw (:std :utf8);
use English qw ( -no_match_vars );

# Модули для работы приложения
use Digest::SHA qw (sha1_base64);
use Hailo;
use Mojo::IOLoop;
use Mojo::Log;
# Чтобы "уж точно" использовать hiredis-биндинги, загрузим этот модуль перед Mojo::Redis
use Protocol::Redis::XS;
use Mojo::Redis;
use Math::Random::Secure qw (irand);
use Text::Fuzzy qw (distance_edits);

use Conf qw (LoadConf);
use version; our $VERSION = qw (1.0);
use Exporter qw (import);
our @EXPORT_OK = qw (RunCraniac);

sub RandomCommonPhrase ();
sub utf2sha1 ($);
sub fmatch (@);
sub brains (@);
sub RunCraniac ();

my $c = LoadConf ();
my $loglevel = $c->{'loglevel'} // 'info';
my $logfile;
my $log;

if (defined $c->{'log'}) {
	$logfile = $c->{'log'};
} elsif (defined $c->{'debug_log'}) {
	$logfile = $c->{'debug_log'};
}

if (defined $logfile) {
	$log = Mojo::Log->new (path => $logfile, level => $loglevel);
} else {
	$log = Mojo::Log->new (path => '/dev/null', level => 'fatal');
}

my $hailo;

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

sub utf2sha1 ($) {
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

sub brains (@) {
	my $chatid = shift;
	my $telegram = shift // 0;

	unless (defined $hailo->{$chatid}) {
		my $cid = $chatid;

		# Костыль, чтобы не портировать данные из телеграммных мозгов
		unless ($telegram) {
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
			return 0;
		}

		$log->info (sprintf 'Lazy init brain: %s', $brainname);
	}

	return 1;
}

# Основной парсер
my $parse_message = sub {
	my $self = shift;
	my $m = shift;
	my $send_to = $m->{plugin};
	my $chatid  = $m->{chatid};
	my $userid  = $m->{userid};
	my $phrase  = $m->{message};
	my $reply;

	# Если $m->{misc}->{answer} не существует, то проставим его как 1, предполагаем, что по-умолчанию ответ от нас
	# всё-таки ожидают. Уточним ниже, по содержимому фразы и по режиму беседы (private или public).
	if (defined $m->{misc}) {
		unless (defined $m->{misc}->{answer}) {
			$m->{misc}->{answer} = 1;
		}
	} else {
		$m->{misc}->{answer} = 1;
	}

	if (defined $m->{misc}->{bot_nick}) {
		# Заменим обращение к боту по нику с окружающими запятыми и пробелами на пробел
		$phrase =~ s/\s*\,?\s*($m->{misc}->{bot_nick})\s*\,?\s*/ /gui;
	}

	if ($m->{mode} eq 'private') {
		$phrase =~ s/^\s*(вот\s+)?скажи(\s*мне)?\s*//gui;
		$phrase =~ s/\s*(,)?\s*а\s*\?$/?/gui;

		if ($phrase =~ /^ *кто +все +эти +люди *\?$/ui) {
			$reply = 'Какие "люди"? Мы здесь вдвоём, только ты и я.';
		} elsif ($phrase =~ /^ *кто +я *\?$/ui) {
			$reply = 'Где?';
		} elsif ($phrase =~ /^ *кто +(здесь|тут) *\?$/ui) {
			$reply = 'Ты да я, да мы с тобой.';
		}

		# TODO: дописать запрос в webapp, для easter egg-ов, либо делать это на уровне aleesa-misc

		if (defined ($reply) && $m->{misc}->{answer}) {
			$self->json ($send_to)->notify (
				$send_to => {
					from    => 'craniac',
					userid  => $userid,
					chatid  => $chatid,
					plugin  => $m->{plugin},
					message => $reply
				}
			);

			return;
		}
	} elsif ($m->{mode} eq 'public') {
		$phrase =~ s/^\s*(вот\s+)?скажи(\s*мне)?\s*//gui;
		$phrase =~ s/\s*(,)?\s*а\s*\?$/?/gui;

		if ($phrase =~ /^ *кто +все +эти +люди *\?$/ui) {
			$reply = 'Кто здесь?';
		} elsif ($phrase =~ /^ *кто +я *?$/ui){
			$reply = 'Где?';
		} elsif ($phrase =~ /^ *кто +(здесь|тут) *\?$/ui) {
			$reply = 'Здесь все: Никита, Стас, Гена, Турбо и Дюша Метёлкин.';
		}

		if (defined ($reply) && $m->{misc}->{answer}) {
			$self->json ($send_to)->notify (
				$send_to => {
					from    => 'craniac',
					userid  => $userid,
					chatid  => $chatid,
					plugin  => $m->{plugin},
					message => $reply
				}
			);

			return;
		}
	}

	# Попадаем сюда только если входящая фраза не распознана ранее как ключевая. 
	if ($m->{misc}->{answer}) {
		# Пытаемся что-то генерировать, если фраза длиннее 3-х букв
		if (length ($m->{message}) > 3) {
			if (brains ($chatid, 1)) {
				$reply = $hailo->{$chatid}->learn_reply ($m->{message});

				# Если из реактора вернулся undef выдаём "общую" фразу из словаря
				unless (defined $reply) {
					$reply = RandomCommonPhrase ();
				} else {
					# Если из реактора вернулась пустота выдаём "общую" фразу из словаря
					if ($reply eq '') {
						$reply = RandomCommonPhrase ();
					}

					# Если сгенерированная фраза слишком похожа на начальную - выдаём "общую" фразу из словаря
					if (fmatch (lc ($m->{message}), lc ($reply))) {
						$reply = RandomCommonPhrase ();
					}
				}

				$self->json ($send_to)->notify (
					$send_to => {
						from    => 'craniac',
						userid  => $userid,
						chatid  => $chatid,
						plugin  => $m->{plugin},
						message => $reply
					}
				);
			}
		}
	} else {
		# пытаемся что-то запоминать, если фраза длиннее 3-х букв
		if (length ($m->{message}) > 3) {
			if (brains ($chatid, 1)) {
				$hailo->{$chatid}->learn ($m->{message});
			}
		}
	}

	return;
};

# Main loop, он же event loop
sub RunCraniac () {
	$log->info ("[INFO] Connecting to $c->{server}, $c->{port}");

	my $redis = Mojo::Redis->new (
		sprintf 'redis://%s:%s/1', $c->{server}, $c->{port}
	);

	$log->info ('[INFO] Registering connection-event callback');

	$redis->on (
		connection => sub {
			my ($r, $connection) = @_;

			$log->info ('[INFO] Triggering callback on new client connection');

			# Пишем ошибку в лог, если соединение с редиской внезапно порвалось.
			$connection->on (
				error => sub {
					my ($conn, $error) = @_;
					$log->error ("[ERROR] Redis connection error: $error");
					return;
				}
			);

			return;
		}
	);

	my $pubsub = $redis->pubsub;
	my $sub;
	$log->info ('[INFO] Subscribing to redis channels');

	foreach my $channel (@{$c->{channels}}) {
		$log->debug ("[DEBUG] Subscribing to $channel");

		$sub->{$channel} = $pubsub->json ($channel)->listen (
			$channel => sub { $parse_message->(@_); }
		);
	}

	do { Mojo::IOLoop->start } until Mojo::IOLoop->is_running;
	return;
}

1;

# vim: set ft=perl noet ai ts=4 sw=4 sts=4:
