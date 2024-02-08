package Plugins::TIDAL::API;

use strict;
use Exporter::Lite;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

our @EXPORT_OK = qw(AURL BURL KURL SCOPES GRANT_TYPE);

use constant AURL => 'https://auth.tidal.com';
use constant BURL => 'https://api.tidal.com/v1';
use constant KURL => 'https://gist.githubusercontent.com/yaronzz/48d01f5a24b4b7b37f19443977c22cd6/raw/5a91ced856f06fe226c1c72996685463393a9d00/tidal-api-key.json';
use constant IURL => 'http://resources.tidal.com/images/';
use constant SCOPES => 'r_usr+w_usr';
use constant GRANT_TYPE => 'urn:ietf:params:oauth:grant-type:device_code';

use constant IMAGE_SIZES => {
	album  => '1280x1280',
	track  => '1280x1280',
	artist => '750x750',
	user   => '600x600',
	mood   => '684x684',
	genre  => '640x426',
	playlist => '1080x720',
	playlistSquare => '1080x1080',
};

my $log = logger('plugin.tidal');
my $prefs = preferences('plugin.tidal');

sub getSomeAccount {
	my $accounts = $prefs->get('accounts');

	my ($account) = keys %$accounts;

	return $account;
}

sub getImageUrl {
	my ($class, $data) = @_;

	if ( my $coverId = $data->{cover} || $data->{image} || $data->{squareImage} || $data->{picture} || ($data->{album} && $data->{album}->{cover}) ) {
		my $type = $class->typeOfItem($data);
		my $iconSize;

		if ($type eq 'playlist' && $data->{squareImage}) {
			$coverId = $data->{squareImage};
			$iconSize ||= IMAGE_SIZES->{playlistSquare};
		}

		$iconSize ||= IMAGE_SIZES->{$type};

		if ($iconSize) {
			$coverId =~ s/-/\//g;
			$data->{cover} = IURL . $coverId . "/$iconSize.jpg";
		}
		else {
			delete $data->{cover};
		}
	}

	return $data->{cover};
}

sub typeOfItem {
	my ($class, $item) = @_;

	if ( $item->{type} && $item->{type} =~ /(?:EXTURL|VIDEO)/ ) {}
	elsif ( defined $item->{hasPlaylists} && $item->{path} ) {
		return 'category';
	}
	elsif ( $item->{type} && $item->{type} =~ /(?:ALBUM|EP|SINGLE)/ ) {
		return 'album';
	}
	# playlist items can be of various types: USER, EDITORIAL etc., but they should have a numberOfTracks element
	elsif ( $item->{type} && defined $item->{numberOfTracks} && ($item->{created} || $item->{creator} || $item->{publicPlaylist} || $item->{lastUpdated}) ) {
		return 'playlist';
	}
	elsif ( defined $item->{mixNumber} && $item->{artists} ) {
		return 'mix'
	}
	# only artists have names? Others have titles?
	elsif ( $item->{name} ) {
		return 'artist';
	}
	# tracks?
	elsif ( !$item->{type} || defined $item->{allowStreaming}) {
		return 'track';
	}
	elsif ( main::INFOLOG ) {
		$log->warn('unknown tidal item type: ' . Data::Dump::dump($item));
	}

	return '';
}


1;