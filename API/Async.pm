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

use Plugins::TIDAL::API qw(BURL DEFAULT_LIMIT PLAYLIST_LIMIT MAX_LIMIT DEFAULT_TTL DYNAMIC_TTL USER_CONTENT_TTL);

use constant CAN_MORE_HTTP_VERBS => Slim::Networking::SimpleAsyncHTTP->can('delete');

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
		updatedPlaylists
	) );

	__PACKAGE__->mk_accessor( hash => qw(
		updatedFavorites
	) );
}

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.tidal');
my $prefs = preferences('plugin.tidal');
my $serverPrefs = preferences('server');

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
		_ttl => $args->{ttl} || DYNAMIC_TTL,
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

sub home {
	my ($self, $cb) = @_;

	$self->page($cb, 'pages/home');
}

sub page {
	my ($self, $cb, $path, $limit) = @_;

	$self->_get("/$path", sub {
		my $page = shift;

		my $items = [];
		# flatten down all modules as they seem to be only one per row
		push @$items, @{$_->{modules}} foreach (@{$page->{rows}});

		$cb->($items || []);
	}, {
		_ttl => DYNAMIC_TTL,
		_personal => 1,
		deviceType => 'BROWSER',
		limit => $limit || DEFAULT_LIMIT,
		locale => lc($serverPrefs->get('language')),
	} );
}

sub dataPage {
	my ($self, $cb, $path, $limit) = @_;

	$self->_get("/$path", sub {
		my $page = shift;

		my $items = $page->{items};

		$cb->($items || []);
	}, {
		_ttl => DYNAMIC_TTL,
		_personal => 1,
		_page => PLAYLIST_LIMIT,
		deviceType => 'BROWSER',
		limit => $limit || DEFAULT_LIMIT,
		locale => lc($serverPrefs->get('language')),
	} );
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
	},{
		limit => MAX_LIMIT
	});
}

sub albumTracks {
	my ($self, $cb, $id) = @_;

	$self->_get("/albums/$id/tracks", sub {
		my $album = shift;
		my $tracks = $album->{items} if $album;
		$tracks = Plugins::TIDAL::API->cacheTrackMetadata($tracks) if $tracks;

		$cb->($tracks || []);
	},{
		limit => MAX_LIMIT
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

# see comment on Plugin::GetFavoritesPlaylists
=comment
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
=cut

sub playlistData {
	my ($self, $cb, $uuid) = @_;

	$self->_get("/playlists/$uuid", sub {
		my $playlist = shift;
		$cb->($playlist);
	}, { _ttl => DYNAMIC_TTL } );
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
		_ttl => DYNAMIC_TTL,
		_refresh => $refresh,
		limit => MAX_LIMIT,
	});
}

# User collections can be large - but have a known last updated timestamp.
# Playlist are more complicated as the list might have changed but also the
# content might have changed. We know if the list of favorite playlists has
# changed and if the content (tbc) of user-created playlists has changed.
# So if the list has changed, we re-read it and iterate playlists to see
# and flag the updated ones so that cache is refreshed next time we access
# these (note that we don't re-read the items, just the playlist).
# But that does not do much good when the list have not changed, we can
# only wait for the playlist's cache ttl to expire (1 day)
# For users-created playlists, the situtation is better because we know that
# the content of at least one has changed, so we re-read and invalidate them
# as describes above, but because we have a flag for content update, changes
# are detected immediately, regardless of cache.

sub getFavorites {
	my ($self, $cb, $type, $refresh) = @_;

	return $cb->() unless $type;

	my $userId = $self->userId || return $cb->();
	my $cacheKey = "tidal_favs_$type:$userId";

	# verify if that type has been updated and force refresh (don't confuse adding
	# a playlist to favorites with changing the *content* of a playlist)
	$refresh ||= $self->updatedFavorites($type);
	$self->updatedFavorites($type, 0);

	my $lookupSub = sub {
		my $timestamp = shift;

		$self->_get("/users/$userId/favorites/$type", sub {
			my $result = shift;

			my $items = [ map { $_->{item} } @{$result->{items} || []} ] if $result;
			$items = Plugins::TIDAL::API->cacheTrackMetadata($items) if $items && $type eq 'tracks';

			# verify if playlists need to be invalidated
			if (defined $timestamp && $type eq 'playlists') {
				foreach my $playlist (@$items) {
					next unless str2time($playlist->{lastUpdated}) > $timestamp;
					main::INFOLOG && $log->is_info && $log->info("Invalidating playlist $playlist->{uuid}");
					# the invalidation flag lives longer than the playlist cache itself
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
		# don't bother verifying timestamp unless we're sure we need to
		return $cb->($cached->{items}) unless $refresh;

		$self->getLatestCollectionTimestamp(sub {
			my ($timestamp, $fullset) = @_;

			# we re-check more than what we should if updatePlaylist has changed, as we could
			# limit to user-made playlist. But that does not cost much to check them all
			if ($timestamp > $cached->{timestamp} || ($type eq 'playlists' && $fullset->{updatedPlaylists} > $cached->{timestamp})) {
				main::INFOLOG && $log->is_info && $log->info("Favorites of type '$type' has changed - updating");
				$lookupSub->($cached->{timestamp});
			}
			else {
				main::INFOLOG && $log->is_info && $log->info("Favorites of type '$type' has not changed - using cached results");
				$cb->($cached->{items});
			}
		}, $type);
	}
	else {
		$lookupSub->();
	}
}

sub getCollectionPlaylists {
	my ($self, $cb, $refresh) = @_;

	my $userId = $self->userId || return $cb->();
	my $cacheKey = "tidal_playlists:$userId";

	$refresh ||= $self->updatedPlaylists();
	$self->updatedPlaylists(0);

	my $lookupSub = sub {
		my $timestamp = shift;

		$self->_get("/users/$userId/playlistsAndFavoritePlaylists", sub {
			my $result = shift;

			my $items = [ map { $_->{playlist} } @{$result->{items} || []} ] if $result;

			foreach my $playlist (@$items) {
				next unless str2time($playlist->{lastUpdated}) > $timestamp;
				main::INFOLOG && $log->is_info && $log->info("Invalidating playlist $playlist->{uuid}");
				$cache->set('tidal_playlist_refresh_' . $playlist->{uuid}, DEFAULT_TTL);
			}

			$cache->set($cacheKey, {
				items => $items,
				timestamp => time(),
			}, '1M') if $items;

			$cb->($items);
		},{
			_nocache => 1,
			# yes, this is the ONLY API THAT HAS A DIFFERENT PAGE LIMIT
			_page => PLAYLIST_LIMIT,
			limit => MAX_LIMIT,
		});
	};

	my $cached = $cache->get($cacheKey);
	if ($cached && ref $cached->{items}) {
		return $cb->($cached->{items}) unless $refresh;

		$self->getLatestCollectionTimestamp(sub {
			my ($timestamp, $fullset) = @_;

			if ($timestamp > $cached->{timestamp} || $fullset->{updatedPlaylists} > $cached->{timestamp}) {
				main::INFOLOG && $log->is_info && $log->info("Collection of playlists has changed - updating");
				$lookupSub->($cached->{timestamp});
			}
			else {
				main::INFOLOG && $log->is_info && $log->info("Collection of playlists has not changed - using cached results");
				$cb->($cached->{items});
			}
		}, 'playlists');
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
		my $key = 'updatedFavorite' . ucfirst($type || '');
		$result->{$_} = (str2time($result->{$_}) || 0) foreach (keys %$result);
		$cb->( $result->{$key}, $result );
	}, { _nocache => 1 });
}

sub updateFavorite {
	my ($self, $cb, $action, $type, $id) = @_;

	my $userId = $self->userId;
	my $key = $type ne 'playlist' ? $type . 'Ids' : 'uuids';
	$type .= 's';

	# make favorites has updated
	$self->updatedFavorites($type, 1);
	$self->updatedPlaylists(1) if $type eq 'playlist';

	if ($action eq 'add') {

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

	# we need an etag, so we need to do a request of one, not cached!
	$self->_get("/playlists/$uuid/items",
		sub {
			my ($result, $response) = @_;
			my $eTag = $response->headers->header('etag');
			$eTag =~ s/"//g;

			# and yes, you're not dreaming, the Tidal API does not allow you to delete
			# a track in a playlist by it's id, you need to provide the item's *index*
			# in the list... OMG
			if ($action eq 'add') {
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
		}, {
		_nocache => 1,
		limit => 1,
		}
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
			my $pageSize = delete $params->{_page} || DEFAULT_LIMIT;

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
			if ($params->{limit} > $pageSize) {
				$maxLimit = $params->{limit};
				$params->{limit} = $pageSize;
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

					if ($maxLimit && $result && ref $result eq 'HASH' && $maxLimit >= $result->{totalNumberOfItems} && $result->{totalNumberOfItems} - $pageSize > 0) {
						my $remaining = $result->{totalNumberOfItems} - $pageSize;
						main::INFOLOG && $log->is_info && $log->info("We need to page to get $remaining more results");

						my @offsets;
						my $offset = $pageSize;
						my $maxOffset = min($maxLimit, MAX_LIMIT, $result->{totalNumberOfItems});
						do {
							push @offsets, $offset;
							$offset += $pageSize;
						} while ($offset < $maxOffset);

						# restore some of the initial params
						$params->{_nocache}  = $noCache;
						$params->{_personal} = $personalCache;
						$params->{_refresh}  = $refresh;
						$params->{_method}   = $method;

						if (scalar @offsets) {
							Async::Util::amap(
								inputs => \@offsets,
								action => sub {
									my ($input, $acb) = @_;
									$self->_call($url, sub {
										# only return the first argument, the second would be considered an error
										$acb->($_[0]);
									}, {
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