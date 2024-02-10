package Plugins::TIDAL::API::Async;

use strict;
use base qw(Slim::Utils::Accessor);

use Data::URIEncode qw(complex_to_query);
use MIME::Base64 qw(encode_base64url encode_base64);
use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::TIDAL::API qw(AURL BURL KURL SCOPES GRANT_TYPE_DEVICE);

use constant TOKEN_PATH => '/v1/oauth2/token';

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
	) );
}

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.tidal');
my $prefs = preferences('plugin.tidal');

my (%deviceCodes, %apiClients, $cid, $sec);

sub init {
	$cid = $prefs->get('cid');
	$sec = $prefs->get('sec');

	__PACKAGE__->fetchKs() unless $cid && $sec;
}

sub new {
	my ($class, $args) = @_;

	if (!$args->{client} && !$args->{userId}) {
		return;
	}

	my $client = $args->{client};
	my $userId = $args->{userId} || $prefs->client($client)->get('userId') || return;

	if (my $apiClient = $apiClients{$userId}) {
		return $apiClient;
	}

	my $self = $apiClients{$userId} = $class->SUPER::new();
	$self->client($client);
	$self->userId($userId);

	return $self;
}

sub search {
	my ($self, $cb, $args) = @_;

	$self->_get('/search' . ($args->{type} || ''), sub {
		my $result = shift;

		my $items = $result->{items} if $result && ref $result;
		$items = Plugins::TIDAL::API->cacheTrackMetadata($items) if $args->{type} =~ /tracks/;

		$cb->($items);
	}, {
		query => $args->{search}
	});
}

sub tracks {
	my ($self, $cb, $id) = @_;

	$self->_get("/tracks/$id", sub {
		my $track = shift;
		($track) = @{ Plugins::TIDAL::API->cacheTrackMetadata([$track]) } if $track;
		$cb->($track);
	});
}

sub artistAlbums {
	my ($self, $cb, $id) = @_;

	$self->_get("/artists/$id/albums", sub {
		my $artist = shift;
		my $albums = $artist->{items} if $artist;
		$cb->($albums || []);
	});
}

sub mix {
	my ($self, $cb, $id) = @_;

	$self->_get("/mixes/$id/items", sub {
		my $mix = shift;

		my $tracks = Plugins::TIDAL::API->cacheTrackMetadata([ map {
			$_->{item}
		} grep {
			$_->{type} && $_->{type} eq 'track'
		} @{$mix->{items} || []} ]) if $mix;

		$cb->($tracks || []);
	}, {
		mixId => $id,
		deviceType => 'BROWSER',
	});
}

sub albumTracks {
	my ($self, $cb, $id) = @_;

	$self->_get("/albums/$id/tracks", sub {
		my $album = shift;
		my $tracks = $album->{items} if $album;
		$tracks = Plugins::TIDAL::API->cacheTrackMetadata($tracks) if $tracks;

		$cb->($tracks || []);
	});
}

sub genres {
	my ($self, $cb) = @_;

	$self->_get('/genres', sub {
		$cb->(@_);
	});
}

sub genreByType {
	my ($self, $cb, $genre, $type) = @_;

	$self->_get("/genres/$genre/$type", sub {
		my $results = shift;
		my $items = $results->{items} if $results;
		$items = Plugins::TIDAL::API->cacheTrackMetadata($items) if $items && $type eq 'tracks';
		$cb->($items || []);
	});
}

sub playlist {
	my ($self, $cb, $uuid) = @_;

	$self->_get("/playlists/$uuid/items", sub {
		my $result = shift;

		my $items = Plugins::TIDAL::API->cacheTrackMetadata([ map {
			$_->{item}
		} grep {
			$_->{type} && $_->{type} eq 'track'
		} @{$result->{items} || []} ]) if $result;

		$cb->($items || []);
	});
}

sub getFavorites {
	my ($self, $cb, $type) = @_;

	return $cb->() unless $type;

	my $userId = $self->userId || return $cb->();

	$self->_get("/users/$userId/favorites/$type", sub {
		my $result = shift;

		my $items = [ map { $_->{item} } @{$result->{items} || []} ] if $result;
		$items = Plugins::TIDAL::API->cacheTrackMetadata($items) if $items && $type eq 'tracks';

		$cb->($items);
	});
}


sub getTrackUrl {
	my ($self, $cb, $id, $params) = @_;

	$self->_get('/tracks/' . $id . '/playbackinfopostpaywall', sub {
		$cb->(@_);
	}, $params);
}

sub initDeviceFlow {
	my ($class, $cb) = @_;

	$class->_authCall('/v1/oauth2/device_authorization', $cb, {
		scope => SCOPES
	});
}

sub pollDeviceAuth {
	my ($class, $args, $cb) = @_;

	my $deviceCode = $args->{deviceCode} || return $cb->();

	$deviceCodes{$deviceCode} ||= $args;
	$args->{expiry} ||= time() + $args->{expiresIn};
	$args->{cb}     ||= $cb if $cb;

	_delayedPollDeviceAuth($deviceCode, $args);
}

sub _delayedPollDeviceAuth {
	my ($deviceCode, $args) = @_;

	Slim::Utils::Timers::killTimers($deviceCode, \&_delayedPollDeviceAuth);

	if ($deviceCodes{$deviceCode} && time() <= $args->{expiry}) {
		__PACKAGE__->_authCall(TOKEN_PATH, sub {
			my $result = shift;

			if ($result) {
				if ($result->{error}) {
					Slim::Utils::Timers::setTimer($deviceCode, time() + ($args->{interval} || 2), \&_delayedPollDeviceAuth, $args);
					return;
				}
				elsif ($result->{user} && $result->{user_id}) {
					my $accounts = $prefs->get('accounts');

					my $userId = $result->{user_id};
					# have token expire a little early
					$cache->set("tidal_at_$userId", $result->{access_token}, $result->{expires_in} - 300);

					$result->{user}->{refreshToken} = $result->{refresh_token};
					$accounts->{$userId} = $result->{user};
					$prefs->set('accounts', $accounts);
				}

				delete $deviceCodes{$deviceCode};
			}

			$args->{cb}->($result) if $args->{cb};
		},{
			scope => SCOPES,
			grant_type => GRANT_TYPE_DEVICE,
			device_code => $deviceCode,
		});

		return;
	}

	# we have timed out
	main::INFOLOG && $log->is_info && $log->info("we have timed out polling for an access token");
	delete $deviceCodes{$deviceCode};

	return $args->{cb}->() if $args->{cb};

	$log->error('no callback defined?!?');
}

sub cancelDeviceAuth {
	my ($class, $deviceCode) = @_;

	return unless $deviceCode;

	Slim::Utils::Timers::killTimers($deviceCode, \&_delayedPollDeviceAuth);
	delete $deviceCodes{$deviceCode};
}

sub fetchKs {
	my ($class) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			my $keys = $result->{keys};

			if ($keys) {
				$keys = [ sort {
					$b->{valid} <=> $a->{valid}
				} grep {
					$_->{cid} && $_->{sec} && $_->{valid}
				} map {
					{
						cid => $_->{clientId},
						sec => $_->{clientSecret},
						valid => $_->{valid} =~ /true/i ? 1 : 0
					}
				} grep {
					$_->{formats} =~ /Normal/
				} @$keys ];

				if (my $key = shift @$keys) {
					$cid = $key->{cid};
					$sec = $key->{sec};
					$prefs->set('cid', $cid);
					$prefs->set('sec', $sec);
				}
			}
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));
		}
	)->get(KURL);
}

sub getToken {
	my ( $self, $cb ) = @_;

	my $userId = $self->userId;
	my $token = $cache->get("tidal_at_$userId");

	return $cb->($token) if $token;

	$self->refreshToken($cb);
}

sub refreshToken {
	my ( $self, $cb ) = @_;

	my $accounts = $prefs->client($self->client)->get('accounts') || {};
	my $profile  = $accounts->{$self->userId};

	if ( $profile && (my $refreshToken = $profile->{refreshToken}) ) {
		__PACKAGE__->_authCall(TOKEN_PATH, sub {
			warn Data::Dump::dump(@_);
			# TODO - store tokens etc.
			$cb->();
		},{
			grant_type => 'refresh_token',
			refresh_token => $refreshToken,
		});
	}
	else {
		# TODO warning
		$cb->();
	}
}

sub _get {
	my ( $self, $url, $cb, $params ) = @_;

	# TODO - caching

	$self->getToken(sub {
		my ($token) = @_;

		if (!$token) {
			my $error = $1 || 'NO_ACCESS_TOKEN';
			$error = 'NO_ACCESS_TOKEN' if $error !~ /429/;

			$cb->({
				name => string('Did not get a token' . $error),
				type => 'text'
			});
		}
		else {
			$params->{countryCode} ||= Plugins::TIDAL::API->getCountryCode($self->userId);

			my %headers = (
				'Authorization' => 'Bearer ' . $token,
			);

			my $query = complex_to_query($params);

			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $response = shift;

					my $result = eval { from_json($response->content) };

					$@ && $log->error($@);
					main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

					$cb->($result);
				},
				sub {
					my ($http, $error) = @_;

					$log->warn("Error: $error");
					main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

					$cb->();
				},
				{
					cache => 1,
				}
			)->get(sprintf('%s%s?%s&limit=%s', BURL, $url, $query, $params->{limit} || 50), %headers);
		}
	});
}

sub _authCall {
	my ( $class, $url, $cb, $params ) = @_;

	my $bearer = encode_base64(sprintf('%s:%s', $cid, $sec));
	$bearer =~ s/\s//g;

	$params->{client_id} ||= $cid;

	warn complex_to_query($params),

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http->contentRef));

			$cb->({
				error => $error || 'failed auth request'
			});
		},
		{
			timeout => 15,
			cache => 0,
			expiry => 0,
		}
	)->post(AURL . $url,
		'Content-Type' => 'application/x-www-form-urlencoded',
		'Authorization' => 'Basic ' . $bearer,
		complex_to_query($params),
	);
}

1;