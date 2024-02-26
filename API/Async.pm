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

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
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

# User collections can be large - but have a known last updated timestamp.
# Instead of statically caching data, then re-fetch everything, do a quick
# lookup to get the latest timestamp first, then return from cache directly
# if the list hasn't changed, or look up afresh if needed.
sub getFavorites {
	my ($self, $cb, $type, $drill) = @_;

	return $cb->() unless $type;

	my $userId = $self->userId || return $cb->();
	my $cacheKey = "tidal_favs_$type:$userId";

	my $lookupSub = sub {
		$self->_get("/users/$userId/favorites/$type", sub {
			my $result = shift;

			my $items = [ map { $_->{item} } @{$result->{items} || []} ] if $result;
			$items = Plugins::TIDAL::API->cacheTrackMetadata($items) if $items && $type eq 'tracks';

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

	# use cached data unless the collection has changed or is small anyway
	my $cached = $cache->get($cacheKey);
	if ($cached && ref $cached->{items}) {
		# don't bother verifying timestamp when drilling down
		return $cb->($cached->{items}) if $drill;
		
		$self->getLatestCollectionTimestamp(sub {
			my $timestamp = shift || 0;

			if ($timestamp > $cached->{timestamp}) {
				$lookupSub->();
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

	$self->_get("/users/$userId/favorites/$type", sub {
		my $result = shift;

		my $latestUpdate;
		eval {
			if ($type eq 'playlists') {
				my $items = $result->{items};

				my $timestamp = reduce {
					my $ta = ref $a ? maxstr($a->{created}, $a->{item}->{lastUpdated}) : $a;
					my $tb = ref $b ? maxstr($b->{created}, $b->{item}->{lastUpdated}) : $b;
					maxstr($ta, $tb);
				} @$items;

				$latestUpdate = str2time($timestamp) || 0;
			}
			else {
				$latestUpdate = str2time($result->{items}->[0]->{created}) || 0;
			}
		};

		($@ || !$latestUpdate) && $log->error("Failed to get '$type' metadata: $@");

		$cb->($latestUpdate);
	},{
		order => 'DATE',
		orderDirection => 'DESC',
		limit => 4,
		_nocache => 1,
	});
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

1;