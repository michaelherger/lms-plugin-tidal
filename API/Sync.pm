package Plugins::TIDAL::API::Sync;

use strict;
use Data::URIEncode qw(complex_to_query);
use Date::Parse qw(str2time);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min);

use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::TIDAL::API qw(BURL DEFAULT_LIMIT MAX_LIMIT PLAYLIST_LIMIT);

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.tidal');

sub getFavorites {
	my ($class, $userId, $type) = @_;

	my $result = $class->_get("/users/$userId/favorites/$type", $userId);

	my $items = [ map {
		my $item = $_;
		$item->{item}->{added} = str2time(delete $item->{created}) if $item->{created};
		$item->{item}->{cover} = Plugins::TIDAL::API->getImageUrl($item->{item});

		foreach (qw(adSupportedStreamReady allowStreaming audioModes audioQuality copyright djReady explicit
			mediaMetadata numberOfVideos popularity premiumStreamingOnly stemReady streamReady
			streamStartDate upc url version vibrantColor videoCover
		)) {
			delete $item->{item}->{$_};
		}

		$item->{item} ;
	} @{$result->{items} || []} ] if $result;

	return $items;
}

sub albumTracks {
	my ($class, $userId, $id) = @_;

	my $album = $class->_get("/albums/$id/tracks", $userId);
	my $tracks = $album->{items} if $album;
	$tracks = Plugins::TIDAL::API->cacheTrackMetadata($tracks) if $tracks;

	return $tracks;
}

sub collectionPlaylists {
	my ($class, $userId) = @_;

	my $result = $class->_get("/users/$userId/playlistsAndFavoritePlaylists", $userId, { _page => PLAYLIST_LIMIT });
	$result = [ map { $_->{playlist} } @{$result->{items} || []} ] if $result;

	my $items = [ map {
		$_->{added} = str2time(delete $_->{created}) if $_->{created};
		$_->{cover} = Plugins::TIDAL::API->getImageUrl($_);
		$_;
	} @$result ] if $result && @$result;

	return $items;
}

sub playlist {
	my ($class, $userId, $uuid) = @_;

	my $playlist = $class->_get("/playlists/$uuid/items", $userId);
	my $tracks = $playlist->{items} if $playlist;
	$tracks = Plugins::TIDAL::API->cacheTrackMetadata($tracks) if $tracks;

	return $tracks;
}

sub getArtist {
	my ($class, $userId, $id) = @_;

	my $artist = $class->_get("/artists/$id", $userId);
	$artist->{cover} = Plugins::TIDAL::API->getImageUrl($artist) if $artist && $artist->{picture};
	return $artist;
}

sub _get {
	my ( $class, $url, $userId, $params ) = @_;

	$userId ||= Plugins::TIDAL::API->getSomeUserId();
	my $token = $cache->get("tidal_at_$userId");
	my $pageSize = delete $params->{_page} || DEFAULT_LIMIT;

	if (!$token) {
		$log->error("Failed to get token for $userId");
		return;
	}

	$params ||= {};
	$params->{countryCode} ||= Plugins::TIDAL::API->getCountryCode($userId);
	$params->{limit} = min($pageSize, $params->{limit} || DEFAULT_LIMIT);

	my $query = complex_to_query($params);

	main::INFOLOG && $log->is_info && $log->info("Getting $url?$query");

	my $response = Slim::Networking::SimpleSyncHTTP->new({
		timeout => 15,
		cache => 1,
		expiry => 86400,
	})->get(BURL . "$url?$query", 'Authorization' => 'Bearer ' . $token);

	if ($response->code == 200) {
		my $result = eval { from_json($response->content) };

		$@ && $log->error($@);
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

		if (ref $result eq 'HASH' && $result->{items} && $result->{totalNumberOfItems}) {
			my $maxItems = min(MAX_LIMIT, $result->{totalNumberOfItems});
			my $offset = ($params->{offset} || 0) + $pageSize;

			if ($maxItems > $offset) {
				my $remaining = $result->{totalNumberOfItems} - $offset;
				main::INFOLOG && $log->is_info && $log->info("We need to page to get $remaining more results");

				my $moreResult = $class->_get($url, $userId, {
					%$params,
					offset => $offset,
				});

				if ($moreResult && ref $moreResult && $moreResult->{items}) {
					push @{$result->{items}}, @{$moreResult->{items}};
				}
			}
		}

		return $result;
	}
	else {
		$log->error("Request failed for $url/$query: " . $response->code);
		main::INFOLOG && $log->info(Data::Dump::dump($response));
	}

	return;
}

1;