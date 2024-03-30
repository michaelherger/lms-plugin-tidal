package Plugins::TIDAL::API::Async;

use strict;
use base qw(Slim::Utils::Accessor);

use Async::Util;
use Data::URIEncode qw(complex_to_query);
use Date::Parse qw(str2time);
use MIME::Base64 qw(encode_base64);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min maxstr reduce);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::TIDAL::API qw(BURL DEFAULT_LIMIT MAX_LIMIT DEFAULT_TTL USER_CONTENT_TTL);

use constant CAN_MORE_HTTP_VERBS => Slim::Networking::SimpleAsyncHTTP->can('delete');

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
		updated
	) );
}

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.tidal');
my $prefs = preferences('plugin.tidal');

my %apiClients;

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

	my $type = $args->{type} || '';
	$type = "/$type" if $type && $type !~ m{^/};

	$self->_get('/search' . $type, sub {
		my $result = shift;

		my $items = $args->{type} ? $result->{items} : $result if $result && ref $result;
		$items = Plugins::TIDAL::API->cacheTrackMetadata($items) if $args->{type} =~ /tracks/;

		$cb->($items);
	}, {
		limit => $args->{limit},
		query => $args->{search}
	});
}

sub track {
	my ($self, $cb, $id) = @_;

	$self->_get("/tracks/$id", sub {
		my $track = shift;
		($track) = @{ Plugins::TIDAL::API->cacheTrackMetadata([$track]) } if $track;
		$cb->($track);
	});
}

sub getArtist {
	my ($self, $cb, $id) = @_;

	$self->_get("/artists/$id", sub {
		$cb->($_[0] || {});
	});
}

sub similarArtists {
	my ($self, $cb, $id) = @_;

	$self->_get("/artists/$id/similar", sub {
		my $result = shift;
		my $items = $result->{items} if $result;
		$cb->($items || []);
	}, {
		limit => MAX_LIMIT,
		_ttl => 3600,
		_personal => 1
	});
}

sub artistAlbums {
	my ($self, $cb, $id, $type) = @_;

	$self->_get("/artists/$id/albums", sub {
		my $artist = shift;
		my $albums = _filterAlbums($artist->{items}) if $artist;
		$cb->($albums || []);
	},{
		limit => MAX_LIMIT,
		filter => $type || 'ALBUMS'
	});
}

sub artistTopTracks {
	my ($self, $cb, $id) = @_;

	$self->_get("/artists/$id/toptracks", sub {
		my $artist = shift;
		my $tracks = Plugins::TIDAL::API->cacheTrackMetadata($artist->{items}) if $artist;
		$cb->($tracks || []);
	},{
		limit => MAX_LIMIT,
	});
}

sub trackRadio {
	my ($self, $cb, $id) = @_;

	$self->_get("/tracks/$id/radio", sub {
		my $result = shift;
		my $tracks = Plugins::TIDAL::API->cacheTrackMetadata($result->{items}) if $result;
		$cb->($tracks || []);
	},{
		limit => MAX_LIMIT,
		_ttl => 3600,
		_personal => 1
	});
}

# try to remove duplicates
sub _filterAlbums {
	my ($albums) = shift || return;

	my %seen;
	return [ grep {
		scalar (grep /^LOSSLESS$/, @{$_->{mediaMetadata}->{tags} || []}) && !$seen{$_->{fingerprint}}++
	} map { {
			%$_,
			fingerprint => join(':', $_->{artist}->{id}, $_->{title}, $_->{numberOfTracks}),
	} } @$albums ];
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
	my ($self, $cb) = @_;

	$self->_get("/mixes/daily/track", sub {
		$cb->(@_);
	}, {
		limit => MAX_LIMIT,
		_ttl => 3600,
		_personal => 1,
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
		_personal => 1
	});
}

sub album {
	my ($self, $cb, $id) = @_;

	$self->_get("/albums/$id", sub {
		my $album = shift;
		$cb->($album);
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

# this one does not check for updates and this is the user's playlist, so the most
# likely to change. See not on GetFavoritePlaylists, but I don't think this needs 
# be used.
sub userPlaylists {
	my ($self, $cb, $userId) = @_;

	$userId ||= $self->userId;

	$self->_get("/users/$userId/playlists", sub {
		my $result = shift;
		my $items = $result->{items} if $result;

		$cb->($items);
	},{
		limit => MAX_LIMIT,
		_ttl => 300,
	})
}

sub playlistData {
	my ($self, $cb, $uuid) = @_;

	$self->_get("/playlists/$uuid", sub {
		my $playlist = shift;
		$cb->($playlist);
	});
}

sub playlist {
	my ($self, $cb, $uuid) = @_;

	# we need to verify that the playlist has not been invalidated
	my $cacheKey = 'tidal_playlist_refresh_' . $uuid;
	my $refresh = $cache->get($cacheKey);

	$self->_get("/playlists/$uuid/items", sub {
		my $result = shift;

		my $items = Plugins::TIDAL::API->cacheTrackMetadata([ map {
			$_->{item}
		} grep {
			$_->{type} && $_->{type} eq 'track'
		} @{$result->{items} || []} ]) if $result;

		$cache->remove($cacheKey) if $refresh;

		$cb->($items || []);
	},{
		_refresh => $refresh,
		limit => MAX_LIMIT,
	});
}

# User collections can be large - but have a known last updated timestamp.
# Instead of statically caching data, then re-fetch everything, do a quick
# lookup to get the latest timestamp first, then return from cache directly
# if the list hasn't changed, or look up afresh if needed.
sub getFavorites {
	my ($self, $cb, $type, $refresh) = @_;

	return $cb->() unless $type;

	my $userId = $self->userId || return $cb->();
	my $cacheKey = "tidal_favs_$type:$userId";

	# verify if that type has been updated and force refresh (don't confuse adding
	# a playlist to favorites with changing the *content* of a playlist)
	if ((my $updated = $self->updated) =~ /$type:/) {
		$self->updated($updated =~ s/$type://r);
		$refresh = 1;
	}

	my $lookupSub = sub {
		my $timestamp = shift;

		$self->_get("/users/$userId/favorites/$type", sub {
			my $result = shift;

			my $items = [ map { $_->{item} } @{$result->{items} || []} ] if $result;
			$items = Plugins::TIDAL::API->cacheTrackMetadata($items) if $items && $type eq 'tracks';

			# verify if home-made playlists need to be invalidated
			if (defined $timestamp && $type =~ /playlist/) {
				foreach my $playlist (@$items) {
					next unless $playlist->{type} =~ /USER/ && str2time($playlist->{lastUpdated}) > $timestamp;
					main::INFOLOG && $log->is_info && $log->info("Invalidating playlist $playlist->{uuid}");
					$cache->set('tidal_playlist_refresh_' . $playlist->{uuid}, DEFAULT_TTL);
				}
			}

			$cache->set($cacheKey, {
				items => $items,
				timestamp => time(),
			}, '1M') if $items;

			$cb->($items);
		},{
			_nocache => 1,
			limit => MAX_LIMIT,
		});
	};

	# use cached data unless the collection has changed
	my $cached = $cache->get($cacheKey);
	if ($cached && ref $cached->{items}) {
		# don't bother verifying timestamp unless we're sure
		return $cb->($cached->{items}) unless $refresh;

		$self->getLatestCollectionTimestamp(sub {
			my ($timestamp, $usertimestamp) = @_;

			if ($timestamp > $cached->{timestamp} || ($type =~ /playlist/ && $usertimestamp > $cached->{timestamp})) {
				main::INFOLOG && $log->is_info && $log->info("Collection of type '$type' has changed - updating");
				$lookupSub->($cached->{timestamp});
			}
			else {
				main::INFOLOG && $log->is_info && $log->info("Collection of type '$type' has not changed - using cached results");
				$cb->($cached->{items});
			}
		}, $type);
	}
	else {
		$lookupSub->();
	}
}

sub getLatestCollectionTimestamp {
	my ($self, $cb, $type) = @_;

	my $userId = $self->userId || return $cb->();

	$self->_get("/users/$userId/favorites", sub {
		my $result = shift;
		my $key = 'updatedFavorite' . ucfirst($type);
		# we always return as well the timestamp of home-made playlists
		$cb->( str2time($result->{$key}) || 0, str2time($result->{updatedPlaylists}) || 0 );
	}, { _nocache => 1 });
}

sub updateFavorite {
	my ($self, $cb, $action, $type, $id) = @_;

	my $userId = $self->userId;

	my $updated = $self->updated;
	$self->updated($updated . "$type:") unless $updated =~ /$type/;

	if ($action =~ /add/) {
		# well... we have a trailing 's' (I know this is hacky... and bad)
		my $key = $type !~ /playlist/ ? substr($type, 0, -1) . 'Ids' : 'uuids';

		my $params = {
			$key => $id,
			onArtifactNotFound => 'SKIP',
		};

		my $headers = { 'Content-Type' => 'application/x-www-form-urlencoded' };

		$self->_post("/users/$userId/favorites/$type",
			sub { $cb->() },
			$params,
			$headers,
		);
	}
	else {
		$self->_delete("/users/$userId/favorites/$type/$id",
			sub { $cb->() },
		);
	}
}

sub updatePlaylist {
	my ($self, $cb, $action, $uuid, $trackIdOrIndex) = @_;

	# mark that playlist as need to be refreshed. After the DEFAULT_TTL
	# the _get will also have forgotten it, no need to cache beyond
	$cache->set('tidal_playlist_refresh_' . $uuid, DEFAULT_TTL);

	$self->_get("/playlists/$uuid/items",
		sub {
			my ($result, $response) = @_;
			my $eTag = $response->headers->header('etag');
			$eTag =~ s/"//g;

			# and yes, you're not dreaming, the Tidal API does not allow you to delete
			# a track in a playlist by it's id, you need to provide the item's *index*
			# in the list... OMG
			if ($action =~ 'add') {
				my $params = {
					trackIds => $trackIdOrIndex,
					onDupes => 'SKIP',
					onArtifactNotFound => 'SKIP',
				};

				my %headers = (
					'Content-Type' => 'application/x-www-form-urlencoded',
				);
				$headers{'If-None-Match'} = $eTag if $eTag;

				$self->_post("/playlists/$uuid/items",
					sub { $cb->() },
					$params,
					\%headers,
				);
			}
			else {
				my %headers;
				$headers{'If-None-Match'} = $eTag if $eTag;

				$self->_delete("/playlists/$uuid/items/$trackIdOrIndex",
					sub { $cb->() },
					{},
					\%headers,
				);
			}
		},
	);
}

sub getTrackUrl {
	my ($self, $cb, $id, $params) = @_;

	$params->{_nocache} = 1;

	$self->_get('/tracks/' . $id . '/playbackinfopostpaywall', sub {
		$cb->(@_);
	}, $params);
}

sub getToken {
	my ( $self, $cb ) = @_;

	my $userId = $self->userId;
	my $token = $cache->get("tidal_at_$userId");

	return $cb->($token) if $token;

	Plugins::TIDAL::API::Auth->refreshToken($cb, $self->userId);
}

sub _get {
	my ( $self, $url, $cb, $params ) = @_;
	$self->_call($url, $cb, $params);
}

sub _post {
	my ( $self, $url, $cb, $params, $headers ) = @_;
	$params ||= {};
	$params->{_method} = 'post';
	$params->{_nocache} = 1;
	$self->_call($url, $cb, $params, $headers);
}

sub _delete { if (CAN_MORE_HTTP_VERBS) {
	my ( $self, $url, $cb, $params, $headers ) = @_;
	$params ||= {};
	$params->{_method} = 'delete';
	$params->{_nocache} = 1;
	$self->_call($url, $cb, $params, $headers);
} else {
	$log->error('Your LMS does not support the DELETE http verb yet - please update!');
	return $_[2]->();
} }

sub _call {
	my ( $self, $url, $cb, $params, $headers ) = @_;

	$self->getToken(sub {
		my ($token) = @_;

		if (!$token) {
			my $error = $1 || 'NO_ACCESS_TOKEN';
			$error = 'NO_ACCESS_TOKEN' if $error !~ /429/;

			$cb->({
				error => 'Did not get a token ' . $error,
			});
		}
		else {
			$params ||= {};
			$params->{countryCode} ||= Plugins::TIDAL::API->getCountryCode($self->userId);

			$headers ||= {};
			$headers->{Authorization} = 'Bearer ' . $token;

			my $ttl = delete $params->{_ttl} || DEFAULT_TTL;
			my $noCache = delete $params->{_nocache};
			my $refresh = delete $params->{_refresh};
			my $personalCache = delete $params->{_personal} ? ($self->userId . ':') : '';
			my $method = delete $params->{_method} || 'get';

			$params->{limit} ||= DEFAULT_LIMIT;

			while (my ($k, $v) = each %$params) {
				$params->{$k} = Slim::Utils::Unicode::utf8toLatin1Transliterate($v);
			}

			my $cacheKey = "tidal_resp:$url:$personalCache" . join(':', map {
				$_ . $params->{$_}
			} sort grep {
				$_ !~ /^_/
			} keys %$params) unless $noCache;

			main::INFOLOG && $log->is_info && $log->info("Using cache key '$cacheKey'") unless $noCache;

			my $maxLimit = 0;
			if ($params->{limit} > DEFAULT_LIMIT) {
				$maxLimit = $params->{limit};
				$params->{limit} = DEFAULT_LIMIT;
			}

			# TODO - make sure we don't pass any of the keys prefixed with an underscore!
			my $query = complex_to_query($params);

			if (!$noCache && !$refresh && (my $cached = $cache->get($cacheKey))) {
				main::INFOLOG && $log->is_info && $log->info("Returning cached data for $url?$query");
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));

				return $cb->($cached);
			}

			main::INFOLOG && $log->is_info && $log->info("$method $url?$query");

			my $http = Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $response = shift;

					my $result = eval { from_json($response->content) } if $response->content;

					$@ && $log->error($@);
					main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

					if ($maxLimit && $result && ref $result eq 'HASH' && $maxLimit > $result->{totalNumberOfItems} && $result->{totalNumberOfItems} - DEFAULT_LIMIT > 0) {
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

					$cb->($result, $response);
				},
				sub {
					my ($http, $error) = @_;

					$log->warn("Error: $error");
					main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

					$cb->();
				},
				{
					cache => ($method eq 'get' && !$noCache) ? 1 : 0,
				}
			);

			if ($method eq 'post') {
				$http->$method(BURL . $url, %$headers, $query);
			}
			else {
				$http->$method(BURL . "$url?$query", %$headers);
			}
		}
	});
}

1;