package Plugins::TIDAL::API::Async;

use strict;
use base qw(Slim::Utils::Accessor);

use Async::Util;
use Data::URIEncode qw(complex_to_query);
use MIME::Base64 qw(encode_base64url encode_base64);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::TIDAL::API qw(AURL BURL KURL SCOPES GRANT_TYPE_DEVICE DEFAULT_LIMIT MAX_LIMIT DEFAULT_TTL USER_CONTENT_TTL);

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
		my $albums = _filterAlbums($artist->{items}) if $artist;
		$cb->($albums || []);
	},{
		limit => MAX_LIMIT,
	});
}

sub _filterAlbums {
	my ($albums) = shift || return;

	# TODO - be a bit smarter about removing duplicates
	return [ grep {
		$_->{audioQuality} !~ /^(?:LOW|HI_RES)$/
	} @$albums ];
}

sub featured {
	my ($self, $cb) = @_;
	$self->_get("/featured", $cb);
}

sub featuredItem {
	my ($self, $cb, $args) = @_;

	my $id = $args->{id};
	my $type = $args->{type};

	return $cb->() unless $id && $type;

	$self->_get("/featured/$id/$type", sub {
		my $items = shift;
		my $tracks = $items->{items} if $items;
		$tracks = Plugins::TIDAL::API->cacheTrackMetadata($tracks) if $tracks && $type eq 'tracks';

		$cb->($tracks || []);
	});
}

sub myMixes {
	my ($self, $cb, $id) = @_;

	$self->_get("/mixes/daily/track", sub {
		$cb->(@_);
	}, {
		limit => MAX_LIMIT,
		_ttl => 3600,
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
		limit => MAX_LIMIT,
		_ttl => 3600,
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
	$self->_get('/genres', $cb);
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

sub moods {
	my ($self, $cb) = @_;
	$self->_get('/moods', $cb);
}

sub moodPlaylists {
	my ($self, $cb, $mood) = @_;

	$self->_get("/moods/$mood/playlists", sub {
		$cb->(@_);
	},{
		limit => MAX_LIMIT,
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
	},{
		limit => MAX_LIMIT,
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
	},{
		_ttl => USER_CONTENT_TTL,
		limit => MAX_LIMIT,
	});
}

sub getTrackUrl {
	my ($self, $cb, $id, $params) = @_;

	$params->{_noCache} = 1;

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
				else {
					_storeTokens($result)
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

	my $accounts = $prefs->get('accounts') || {};
	my $profile  = $accounts->{$self->userId};

	if ( $profile && (my $refreshToken = $profile->{refreshToken}) ) {
		__PACKAGE__->_authCall(TOKEN_PATH, sub {
			$cb->(_storeTokens(@_));
		},{
			grant_type => 'refresh_token',
			refresh_token => $refreshToken,
		});
	}
	else {
		$log->error('Did find neither access nor refresh token. Please re-authenticate.');
		# TODO expose warning on client
		$cb->();
	}
}

sub _storeTokens {
	my ($result) = @_;

	if ($result->{user} && $result->{user_id} && $result->{access_token}) {
		my $accounts = $prefs->get('accounts');

		my $userId = $result->{user_id};
		# have token expire a little early
		$cache->set("tidal_at_$userId", $result->{access_token}, $result->{expires_in} - 300);

		$result->{user}->{refreshToken} = $result->{refresh_token};
		$accounts->{$userId} = $result->{user};
		$prefs->set('accounts', $accounts);
	}

	return $result->{access_token};
}


my $URL_REGEX = qr{^https://(?:\w+\.)?tidal.com/(?:browse/)?(track|playlist|album|artist|mix)/([a-z\d-]+)}i;
my $URI_REGEX = qr{^wimp://(playlist|album|artist|mix|):?([0-9a-z-]+)}i;
sub getIdsForURL {
	my ( $self, $c ) = @_;

	my $uri = $c->req->params->{url};

	my ($type, $id) = $uri =~ $URL_REGEX;

	if ( !($type && $id) ) {
		($type, $id) = $uri =~ $URI_REGEX;
	}

	$type ||= 'track';
	my $result;
	my $tracks;

	if ($type eq 'playlist') {
		$result = $c->stash->{w}->getPlaylistTracks( $id ) || [];
	}
	elsif ($type eq 'album') {
		$result = $c->stash->{w}->getAlbumTracks( $id ) || [];
	}
	elsif ($type eq 'artist') {
		$result = $c->stash->{w}->getArtistTracks( $id ) || [];
	}
	elsif ($type eq 'mix') {
		$result = $c->stash->{w}->getMix( $id ) || [];
	}
	elsif ($id) {
		if (my $track = $c->stash->{w}->getTrack( $id )) {
			$tracks = [ 'wimp://' . $track->{id} . $c->forward( '/api/wimp/v1/opml/getExt', [ $track ] ) ]
		}
	}

	$tracks ||= [ grep /.+/, map {
		$_->{play};
	} @{$c->forward( '/api/wimp/v1/opml/renderItemList', [ $result || [] ])} ];

	$c->forward( '/api/set_cache', [ 0 ] );
	$c->res->body( to_json( \@$tracks ) );
}


sub _get {
	my ( $self, $url, $cb, $params ) = @_;

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

			my $ttl = delete $params->{_ttl} || DEFAULT_TTL;
			my $noCache = delete $params->{_nocache};

			$params->{limit} ||= DEFAULT_LIMIT;

			my $cacheKey = "tidal_resp:$url:" . join(':', map {
				$_ . $params->{$_}
			} sort grep {
				$_ !~ /^_/
			} keys %$params);

			main::INFOLOG && $log->is_info && $log->info("Using cache key '$cacheKey'") unless $noCache;

			my $maxLimit = 0;
			if ($params->{limit} > DEFAULT_LIMIT) {
				$maxLimit = $params->{limit};
				$params->{limit} = DEFAULT_LIMIT;
			}

			my $query = complex_to_query($params);

			if (!$noCache && (my $cached = $cache->get($cacheKey))) {
				main::INFOLOG && $log->is_info && $log->info("Returning cached data for $url?$query");
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));

				return $cb->($cached);
			}

			main::INFOLOG && $log->is_info && $log->info("Getting $url?$query");

			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $response = shift;

					my $result = eval { from_json($response->content) };

					$@ && $log->error($@);
					main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

					if ($maxLimit && ref $result eq 'HASH' && $maxLimit > $result->{totalNumberOfItems} && $result->{totalNumberOfItems} - DEFAULT_LIMIT > 0) {
						my $remaining = $result->{totalNumberOfItems} - DEFAULT_LIMIT;
						main::INFOLOG && $log->is_info && $log->info("We need to page to get $remaining more results");

						my @offsets;
						my $offset = DEFAULT_LIMIT;
						my $maxOffset = min($maxLimit, MAX_LIMIT, $result->{totalNumberOfItems});
						do {
							push @offsets, $offset;
							$offset += DEFAULT_LIMIT;
						} while ($offset < $maxOffset);

						if (scalar @offsets) {
							Async::Util::amap(
								inputs => \@offsets,
								action => sub {
									my ($input, $acb) = @_;
									$self->_get($url, $acb, {
										%$params,
										offset => $input,
									});
								},
								at_a_time => 4,
								cb => sub {
									my ($results, $error) = @_;

									foreach (@$results) {
										next unless ref $_ && $_->{items};
										push @{$result->{items}}, @{$_->{items}};
									}

									$cache->set($cacheKey, $result, $ttl) unless $noCache;

									$cb->($result);
								}
							);

							return;
						}
					}

					$cache->set($cacheKey, $result, $ttl) unless $noCache;

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
			)->get(BURL . "$url?$query", %headers);
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