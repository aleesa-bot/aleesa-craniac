package Craniac;
# Предполагается, что craniac - это "маршрут по-умолчанию". То есть сюда попадают все фразы, которые не были распознаны
# aleesa-misc как команды. В том числе и некоторые команды (но по идее это так и задумано).

# Основная задача мозгов - распознать, требуется ли ответ и обработать фразу.
# Соответсвенно, мы предполагаем, что фразы делятся на 2 типа:
# * ключевая фраза, на которую у нас есть один или несколько готовых ответов.
# * просто фраза в чате, на которую надо напрячь мозги и (в зависимости от необходимости) ответить на неё или 
#   проигнорировать.

# Общие модули - синтаксис, кодировки итд
use 5.018; ## no critic (ProhibitImplicitImport)
use strict;
use warnings;
use utf8;
use open qw (:std :utf8);
use English qw ( -no_match_vars );

# Модули для работы приложения
use Clone qw (clone);
use Data::Dumper qw (Dumper);
use Digest::SHA qw (sha256_hex);
use File::Spec ();
use Hailo ();
use Log::Any qw ($log);
use Mojo::IOLoop ();
use Mojo::IOLoop::Signal ();
use Mojo::Redis ();
use Math::Random::Secure qw (irand);
use Text::Fuzzy qw (distance_edits);

use Conf qw (LoadConf);
use Craniac::Lat qw (Lat);

use version; our $VERSION = qw (1.0);
use Exporter qw (import);
our @EXPORT_OK = qw (RunCraniac);

sub RandomCommonPhrase ();
sub fmatch (@);
sub brains (@);
sub RunCraniac ();

my $c = LoadConf ();
my $fwd_cnt = $c->{'forward_max'} // 5;

my $hailo;

# Несколько фраз общего характера, используемые как универсальный ответ, когда ответить нечего (по тем или иным
# причинам) или ответ не будет достаточно вменяемым (слишком похож на фразу, на которую отвечаем)
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

# Ленивая инициализация мозга. Создаём/открываем мозг только если нам надо "подумать" а не на каждую входящую фразу.
sub brains (@) {
	my $plugin = shift;
	my $cid = shift;

	unless (defined $hailo->{$cid}) {
		my $brainname;

		# Костыль, чтобы не портировать данные из телеграммных мозгов и не заниматься переименованием
		if ($plugin eq 'telegram') {
			$brainname = sprintf '%s/%s.brain.sqlite', $c->{braindir}, $cid;
		} else {
			$brainname = sprintf '%s/%s.sqlite', $c->{braindir}, $cid;
		}

		$hailo->{$cid} = eval {
			Hailo->new (
				brain => $brainname,
				order => 3,
			);
		};

		if (defined $hailo->{$cid}) {
			$log->info (sprintf '[INFO] Lazy init brain: %s', $brainname);
		} else {
			$log->error ("[ERROR] $EVAL_ERROR");
			return 0;
		}
	}

	return 1;
}

# Основной парсер
my $parse_message = sub {
	my $self = shift;
	my $m    = shift;

	my $answer = clone ($m);
	$answer->{from} = 'craniac';

	my $send_to = $m->{plugin};
	my $chatid  = $m->{chatid};
	my $userid  = $m->{userid};
	my $phrase  = $m->{message};
	my $reply;

	if (defined $answer->{misc}) {
		unless (defined $answer->{misc}->{answer}) {
			$answer->{misc}->{answer} = 1;
		}

		unless (defined $answer->{misc}->{bot_nick}) {
			$answer->{misc}->{bot_nick} = '';
		}

		unless (defined $answer->{misc}->{csign}) {
			$answer->{misc}->{csign} = $c->{csign};
		}

		unless (defined $answer->{misc}->{fwd_cnt}) {
			$answer->{misc}->{fwd_cnt} = 1;
		} else {
			if ($answer->{misc}->{fwd_cnt} > $fwd_cnt) {
				$log->error ('[ERROR] Forward loop detected, discarding message.');
				$log->debug (Dumper $m);
				return;
			} else {
				$answer->{misc}->{fwd_cnt}++;
			}
		}

		unless (defined $answer->{misc}->{good_morning}) {
			$answer->{misc}->{good_morning} = 0;
		}

		unless (defined $answer->{misc}->{msg_format}) {
			$answer->{misc}->{msg_format} = 0;
		}

		unless (defined $answer->{misc}->{username}) {
			$answer->{misc}->{username} = 'user';
		}
	} else {
		$answer->{misc}->{answer} = 1;
		$answer->{misc}->{bot_nick} = '';
		$answer->{misc}->{csign} = $c->{csign};
		$answer->{misc}->{fwd_cnt} = 1;
		$answer->{misc}->{good_morning} = 0;
		$answer->{misc}->{msg_format} = 0;
		$answer->{misc}->{username} = 'user';
	}

	my $csign = $answer->{misc}->{csign};
	$answer->{message} = '';

	my $is_command = 0;
	my $cmd = $m->{message};

	if ($m->{message} =~ /^\Q$csign/u) {
		$cmd = substr $m->{message}, length ($csign);
		$is_command = 1;
	}

	if ($m->{misc}->{bot_nick} ne '') {
		# Если нам сообщили ник бота, попробуем вымарать его из оригинального текста сообщения, в большинстве случаев он
		# нам не интересен.
		$phrase =~ s/\s*\,?\s*($m->{misc}->{bot_nick})\s*\,?\s*/ /gui;

		# TODO: проработать реакцию на "пьяный бред".

		# В ключевых фразах можно обратиться с некоторыми командами к боту по нику, не используя символ команды
		if ($m->{message} =~ /^\s*\Q$m->{misc}->{bot_nick}\E\s*$/ui) {
			$reply = 'Чего?';
		} elsif ($m->{message} =~ /^(\Q$csign\E|\Q$m->{misc}->{bot_nick}\E\s*\,?\s+)ping\.?\s*$/i) {
			$reply = 'Pong.';
		} elsif ($m->{message} =~ /^(\Q$csign\E|\Q$m->{misc}->{bot_nick}\E\s*\,?\s+)pong\.?\s*$/i) {
			$reply = 'Wat?';
		} elsif ($m->{message} =~ /^(\Q$csign\E|\Q$m->{misc}->{bot_nick}\E\s*\,?\s+)пин(г|х)\.?\s*$/ui) {
			$reply = 'Понг.';
		} elsif ($m->{message} =~ /^(\Q$csign\E|\Q$m->{misc}->{bot_nick}\E\s*\,?\s+)пон(г|х)\.?\s*$/ui) {
			$reply = 'Шта?';
		} elsif ($m->{message} =~ /^(\Q$csign\E|\Q$m->{misc}->{bot_nick}\E\s*\,?\s+)(хэлп|halp)\s*$/ui) {
			$reply = 'HALP!!!11';
		}
	} else {
		# Если нам не сообщили ник бота, то ищем команды, используя символ команды
		if ($is_command) {
			if ($cmd =~ /^ping\.?\s*$/ui) {
				$reply = 'Pong.';
			} elsif ($cmd =~ /^pong\.?\s*$/i) {
				$reply = 'Wat?';
			} elsif ($cmd=~ /^пин(г|х)\.?\s*$/ui) {
				$reply = 'Понг.';
			} elsif ($cmd =~ /^пон(г|х)\.?\s*$/ui) {
				$reply = 'Шта?';
			} elsif ($cmd=~ /^(хэлп|halp)\s*$/ui) {
				$reply = 'HALP!!!11';
			}
		}
	}

	# Поищем в тексте входящего сообщения команды общего плана, с символом команды.
	unless (defined $reply) {
		if ($is_command) {
			if ($cmd =~ /^(kde|кде)\s*$/ui) {
				my @phrases = (
					'Нет, я не буду поднимать вам плазму.',
					'Повторяйте эту мантру по утрам не менее 5 раз: "Плазма не падает." И, возможно, она перестанет у вас падать.',
					'Плазма не падает, она просто выходит отдохнуть.',
					'Плазма это не агрегатное состояние, это суперпозиция. Во время работы она находится сразу в жидком, мягком и тёплом состояниях.',
				);

				$reply = $phrases[irand ($#phrases + 1)];
			} elsif ($cmd =~ /^(coin|монетка)$/ui) {
				# Нам тут говорили, что есть некая вероятность, что монета упадёт ребром... И даже цифры называли.
				if (rand (101) < 0.016) {
					$reply = 'ребро';
				} else {
					if (irand (2) == 0) {
						if (irand (2) == 0) {
							$reply = 'орёл';
						} else {
							$reply = 'аверс';
						}
					} else {
						if (irand (2) == 0) {
							$reply = 'решка';
						} else {
							$reply = 'реверс';
						}
					}
				}
			} elsif ($cmd =~ /^(roll|dice|кости)$/ui) {
				$reply = sprintf 'На первой кости выпало %d, а на второй — %d.', irand (6) + 1, irand (6) + 1;
			} elsif ($cmd =~ /^(ver|version|версия)$/ui) {
				$reply = 'Версия:  Четыре.Технологическое_превью';
			} elsif ($cmd =~ /^(lat|лат)\s*$/ui) {
				$reply = Lat ();
			}
		}
	}

	# У нас уже есть чего ответить, нам попалась известная фраза, на которую одинаковый ответ, независимо от типа
	# общения - публичного или приватного.
	if (defined $reply) {
		if ($m->{misc}->{answer}) {
			$answer->{message} = $reply;

			$self->json ($send_to)->notify (
				$send_to => $answer,
			);
		}
	} else {
		# Пока что нам нечего ответить, известных фраз не нашлось. Ищем дальше, на сей раз фразы, зависящие от режима
		# общения - приватного или публичного.
		if ($m->{mode} eq 'private') {
			# Если указанной в unless-е строки во фразе нету, то можно поискать другие приватные фразы
			unless ($phrase =~ s/^\s*(вот\s+)?скажи(\s*мне)?\s*//gui) {
				if ($phrase =~ /покажи +(сиськи|сиси|титьки)\s*$/ui) {
					$send_to = 'webapp';
					$reply = '!boobs';
				} elsif ($phrase =~ /show +(titts|tities|boobs)\s*$/i) {
					$send_to = 'webapp';
					$reply = '!boobs';
				} elsif ($phrase =~ /покажи +(попку|попу) *$/ui) {
					$send_to = 'webapp';
					$reply = '!ass';
				} elsif ($phrase =~ /show +(ass|butt|butty) *$/i) {
					$send_to = 'webapp';
					$reply = '!ass';
				}
			}

			unless (defined $reply) {
				$phrase =~ s/\s*(,)?\s*а\s*\?$/?/gui;

				if ($phrase =~ /^\s*кто\s+все\s+эти\s+люди\s*\?\s*$/ui) {
					$reply = 'Какие "люди"? Мы здесь вдвоём, только ты и я.';
				} elsif ($phrase =~ /^\s*кто\s+я\s*\?\s*$/ui) {
					$reply = 'Где?';
				} elsif ($phrase =~ /^\s*кто\s+(здесь|тут)\s*\?\s*$/ui) {
					$reply = 'Ты да я, да мы с тобой.';
				}
			}

			# TODO: дописать запрос в webapp, для easter egg-ов, либо делать это на уровне aleesa-misc
			if (defined ($reply) && $m->{misc}->{answer}) {
				$answer->{message} = $reply;

				$self->json ($send_to)->notify (
					$send_to => $answer,
				);

				return;
			}
		} elsif ($m->{mode} eq 'public') {
			$phrase =~ s/^\s*(вот\s+)?скажи(\s*мне)?\s*//gui;
			$phrase =~ s/\s*(,)?\s*а\s*\?$/?/gui;

			if ($phrase =~ /^\s*кто\s+все\s+эти\s+люди\s*\?\s*$/ui) {
				$reply = 'Кто здесь?';
			} elsif ($phrase =~ /^\s*кто\s+я\s*?\s*$/ui){
				$reply = 'Где?';
			} elsif ($phrase =~ /^\s*кто\s+(здесь|тут)\s*\?\s*$/ui) {
				$reply = 'Здесь все: Никита, Стас, Гена, Турбо и Дюша Метёлкин.';
			}

			if (defined ($reply) && $m->{misc}->{answer}) {
				$answer->{message} = $reply;

				$self->json ($send_to)->notify (
					$send_to => $answer,
				);

				return;
			}
		}

		# Попадаем сюда только если входящая фраза не распознана ранее как ключевая.
		my $cid;

		if ($m->{plugin} eq 'telegram') {
			$cid = $chatid;
		} else {
			$cid = sha256_hex (sprintf '%s/%s', $m->{plugin}, $chatid);
		}

		if ($m->{misc}->{answer}) {
			# Пытаемся что-то генерировать, если фраза длиннее 3-х букв.
			if (length ($m->{message}) > 3) {
				# Lazy brain init
				if (brains ($m->{plugin}, $cid)) {
					$reply = $hailo->{$cid}->learn_reply ($m->{message});

					# Если из реактора вернулся undef выдаём "общую" фразу из словаря.
					unless (defined $reply) {
						$reply = RandomCommonPhrase ();
					} else {
						# Если из реактора вернулась пустота выдаём "общую" фразу из словаря.
						if ($reply eq '') {
							$reply = RandomCommonPhrase ();
						}

						# Если сгенерированная фраза слишком похожа на начальную - выдаём "общую" фразу из словаря.
						if (fmatch (lc ($m->{message}), lc ($reply))) {
							$reply = RandomCommonPhrase ();
						}
					}

					$answer->{message} = $reply;

					$self->json ($send_to)->notify (
						$send_to => $answer,
					);
				}
			}
		} else {
			# Пытаемся что-то запоминать, если фраза длиннее 3-х букв
			if (length ($m->{message}) > 3) {
				# Lazy brain init
				if (brains ($m->{plugin}, $cid)) {
					$hailo->{$cid}->learn ($m->{message});
				}
			}
		}
	}

	return;
};

my $__signal_handler = sub {
	my ($self, $name) = @_;
	$log->info ("[INFO] Caught a signal $name");

	if (defined $main::pidfile && -e $main::pidfile) {
		unlink $main::pidfile;
	}

	exit 0;
};


# Main loop, он же event loop
sub RunCraniac () {
	$log->info ("[INFO] Connecting to $c->{server}, $c->{port}");

	my $redis = Mojo::Redis->new (
		sprintf 'redis://%s:%s/1', $c->{server}, $c->{port},
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
				},
			);

			return;
		},
	);

	my $pubsub = $redis->pubsub;
	my $sub;
	$log->info ('[INFO] Subscribing to redis channels');

	foreach my $channel (@{$c->{channels}}) {
		$log->debug ("[DEBUG] Subscribing to $channel");

		$sub->{$channel} = $pubsub->json ($channel)->listen (
			$channel => sub { $parse_message->(@_); },
		);
	}

	Mojo::IOLoop::Signal->on (TERM => $__signal_handler);
	Mojo::IOLoop::Signal->on (INT  => $__signal_handler);

	do { Mojo::IOLoop->start } until Mojo::IOLoop->is_running;
	return;
}

1;

# vim: set ft=perl noet ai ts=4 sw=4 sts=4:
