package Plugins::TIDAL::Importer;

use strict;

use base qw(Slim::Plugin::OnlineLibraryBase);

use Date::Parse qw(str2time);
use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(max);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);

use constant ACCOUNTS_URL  => '/api/wimp/v1/opml/library/getAccounts';
use constant ALBUMS_URL    => '/api/wimp/v1/opml/library/myAlbums?account=%s';
use constant ARTISTS_URL   => '/api/wimp/v1/opml/library/myArtists?account=%s';
use constant ARTIST_URL    => '/api/wimp/v1/opml/library/getArtist?id=%s';
use constant PLAYLISTS_URL => '/api/wimp/v1/opml/library/myPlaylists?account=%s';
use constant FINGERPRINT_URL => '/api/wimp/v1/opml/library/fingerprint';

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.tidal');
my $prefs = preferences('plugin.tidal');

my ($ct, $splitChar);

sub startScan { if (main::SCANNER) {
	my ($class) = @_;

	require Plugins::TIDAL::API::Sync;
	$ct = Plugins::TIDAL::API::getFormat();
	$splitChar = substr(preferences('server')->get('splitList'), 0, 1);

	my $accounts = _enabledAccounts();

	if (scalar keys %$accounts) {
		my $playlistsOnly = Slim::Music::Import->scanPlaylistsOnly();

		$class->initOnlineTracksTable();

		if (!$playlistsOnly) {
			$class->scanAlbums($accounts);
			$class->scanArtists($accounts);
		}

		if (!$class->ignorePlaylists) {
			$class->scanPlaylists($accounts);
		}

		$class->deleteRemovedTracks();
		$cache->set('tidal_library_last_scan', time(), '1y');
	}

	Slim::Music::Import->endImporter($class);
} }

sub scanAlbums { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_tidal_albums',
		'total' => 1,
		'every' => 1,
	});

	while (my ($accountName, $userId) = each %$accounts) {
		my %missingAlbums;

		main::INFOLOG && $log->is_info && $log->info("Reading albums... " . $accountName);
		$progress->update(string('PLUGIN_TIDAL_PROGRESS_READ_ALBUMS', $accountName));

		my $albums = Plugins::TIDAL::API::Sync->getFavorites($userId, 'albums');
		$progress->total(scalar @$albums);

		foreach my $album (@$albums) {
			my $albumDetails = $cache->get('tidal_album_with_tracks_' . $album->{id});

			if (0&&$albumDetails && $albumDetails->{tracks} && ref $albumDetails->{tracks}) {
				$progress->update($album->{title});

				$class->storeTracks([
					map { _prepareTrack($albumDetails, $_) } @{ $albumDetails->{tracks} }
				], undef, $accountName);

				main::SCANNER && Slim::Schema->forceCommit;
			}
			else {
				$missingAlbums{$album->{id}} = $album;
			}
		}

		while ( my ($albumId, $album) = each %missingAlbums ) {
			$progress->update($album->{title});

			$album->{tracks} = Plugins::TIDAL::API::Sync->albumTracks($userId, $albumId);

			if (!$album->{tracks}) {
				$log->warn("Didn't receive tracks for $album->{title}/$album->{id}");
				next;
			}

			$cache->set('tidal_album_with_tracks_' . $albumId, $album, '3M');

			$class->storeTracks([
				map { _prepareTrack($album, $_) } @{ $album->{tracks} }
			], undef, $accountName);

			main::SCANNER && Slim::Schema->forceCommit;
		}
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanArtists { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_tidal_artists',
		'total' => 1,
		'every' => 1,
	});

	while (my ($accountName, $userId) = each %$accounts) {
		main::INFOLOG && $log->is_info && $log->info("Reading artists... " . $accountName);
		$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_ARTISTS', $accountName));

		my $artists = Plugins::TIDAL::API::Sync->getFavorites($userId, 'artists');

		$progress->total($progress->total + scalar @$artists);

		foreach my $artist (@$artists) {
			my $name = $artist->{name};

			$progress->update($name);
			main::SCANNER && Slim::Schema->forceCommit;

			Slim::Schema::Contributor->add({
				'artist' => $class->normalizeContributorName($name),
				'extid'  => 'tidal:artist:' . $artist->{id},
			});

			_cacheArtistPictureUrl($artist, '3M');
		}
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanPlaylists { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $dbh = Slim::Schema->dbh();
	my $insertTrackInTempTable_sth = $dbh->prepare_cached("INSERT OR IGNORE INTO online_tracks (url) VALUES (?)") if !$main::wipe;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_tidal_playlists',
		'total' => 0,
		'every' => 1,
	});

	main::INFOLOG && $log->is_info && $log->info("Removing playlists...");
	$progress->update(string('PLAYLIST_DELETED_PROGRESS'), $progress->done);
	my $deletePlaylists_sth = $dbh->prepare_cached("DELETE FROM tracks WHERE url LIKE 'tidal://playlist:%'");
	$deletePlaylists_sth->execute();

	while (my ($accountName, $userId) = each %$accounts) {
		$progress->update(string('PLUGIN_TIDAL_PROGRESS_READ_PLAYLISTS', $accountName), $progress->done);

		main::INFOLOG && $log->is_info && $log->info("Reading playlists for $accountName...");
		my $playlists = Plugins::TIDAL::API::Sync->getFavorites($userId, 'playlists') || [];
		my $userPlaylists = Plugins::TIDAL::API::Sync->userPlaylists($userId);
		push @$playlists, @$userPlaylists if $userPlaylists;

		$progress->total($progress->total + @$playlists);

		my $prefix = 'TIDAL' . string('COLON') . ' ';

		main::INFOLOG && $log->is_info && $log->info(sprintf("Importing tracks for %s playlists...", scalar @$playlists));
		foreach my $playlist (@{$playlists || []}) {
			my $uuid = $playlist->{uuid} or next;

			my $tracks = Plugins::TIDAL::API::Sync->playlist($userId, $uuid);

			$progress->update($accountName . string('COLON') . ' ' . $playlist->{title});
			Slim::Schema->forceCommit;

			my $url = "tidal://playlist:$uuid";

			my $playlistObj = Slim::Schema->updateOrCreate({
				url        => $url,
				playlist   => 1,
				integrateRemote => 1,
				attributes => {
					TITLE        => $prefix . $playlist->{title},
					COVER        => $playlist->{cover},
					AUDIO        => 1,
					EXTID        => $url,
					CONTENT_TYPE => 'ssp'
				},
			});

			my @trackIds = map { "tidal://$_->{id}.$ct" } @$tracks;

			$playlistObj->setTracks(\@trackIds) if $playlistObj && scalar @trackIds;
			$insertTrackInTempTable_sth && $insertTrackInTempTable_sth->execute($url);
		}

		Slim::Schema->forceCommit;
	}

	$progress->final();
	Slim::Schema->forceCommit;
} }

sub getArtistPicture { if (main::SCANNER) {
	my ($class, $id) = @_;

	my $url = $cache->get('tidal_artist_image' . $id);

	return $url if $url;

	$id =~ s/tidal:artist://;

	my $artist = Plugins::TIDAL::API::Sync->getArtist(undef, $id) || {};

	if ($artist->{cover}) {
		_cacheArtistPictureUrl($artist, '3M');
		return $artist->{cover};
	}

	return;
} }

my $previousArtistId = '';
sub _cacheArtistPictureUrl {
	my ($artist, $ttl) = @_;

	if ($artist->{cover} && $artist->{id} ne $previousArtistId) {
		$cache->set('tidal_artist_image' . 'tidal:artist:' . $artist->{id}, $artist->{cover}, $ttl || '3M');
		$previousArtistId = $artist->{id};
	}
}

sub trackUriPrefix { 'tidal://' }

# This code is not run in the scanner, but in LMS
sub needsUpdate { if (!main::SCANNER) {
	my ($class, $cb) = @_;

	my $lastScanTime = $cache->get('tidal_library_last_scan') || return $cb->(1);

	my $checkFav = sub {
		my ($userId, $type, $previous, $acb) = @_;

		Plugins::TIDAL::API::Async->new({
			userId => $userId
		})->getLatestCollectionTimestamp(sub {
			my $timestamp = shift;
			$acb->($timestamp > $lastScanTime);
		}, $type);
	};

	my $workers = [ map {
		my $userId = $_;
		my @tasks = (
			sub { $checkFav->($userId, 'albums', @_) },
			sub { $checkFav->($userId, 'artists', @_) },
		);

		if (!$class->ignorePlaylists) {
			push @tasks, sub { $checkFav->($userId, 'playlists', @_) };
		}

		@tasks;
	} sort {
		$a <=> $b
	} values %{_enabledAccounts()} ];

	Async::Util::achain(
		steps => $workers,
		cb => sub {
			my ($result, $error) = @_;
			$cb->($result && !$error);
		}
	);
} }

sub _enabledAccounts {
	my $accounts = $prefs->get('accounts');
	my $dontImportAccounts = $prefs->get('dontImportAccounts');

	my $enabledAccounts = {};

	while (my ($id, $account) = each %$accounts) {
		$enabledAccounts->{$account->{nickname} || $account->{username}} = $id unless $dontImportAccounts->{$id}
	}

	return $enabledAccounts;
}

sub _prepareTrack {
	my ($album, $track) = @_;

	$ct ||= Plugins::TIDAL::API::getFormat();
	my $url = 'tidal://' . $track->{id} . ".$ct";

	my $trackData = {
		url          => $url,
		TITLE        => $track->{title},
		ARTIST       => $track->{artist}->{name},
		ARTIST_EXTID => 'tidal:artist:' . $track->{artist}->{id},
		ALBUM        => $album->{title},
		ALBUM_EXTID  => 'tidal:album:' . $album->{id},
		TRACKNUM     => $track->{tracknum},
		GENRE        => 'TIDAL',
		DISC         => $track->{disc},
		DISCC        => $album->{numberOfVolumes} || 1,
		SECS         => $track->{duration},
		YEAR         => substr($album->{releaseDate} || '', 0, 4),
		COVER        => $album->{cover},
		AUDIO        => 1,
		EXTID        => $url,
		TIMESTAMP    => $album->{added},
		CONTENT_TYPE => $ct,
		LOSSLESS     => $ct eq 'flc' ? 1 : 0,
		RELEASETYPE  => $album->{type},
	};

	my @trackArtists = map { $_->{name} } grep { $_->{name} ne $track->{artist}->{name} } @{ $track->{artists} };
	if (scalar @trackArtists) {
		$splitChar ||= substr(preferences('server')->get('splitList'), 0, 1);
		$trackData->{TRACKARTIST} = join($splitChar, @trackArtists);
	}

	return $trackData;
}

1;