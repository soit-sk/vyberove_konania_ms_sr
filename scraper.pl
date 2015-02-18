#!/usr/bin/perl

use strict;
use warnings;

use URI;
use FindBin;
use lib $FindBin::Bin;
use WWW::Mechanize;
use HTML::TreeBuilder;
use Database::DumpTruck;

use utf8;
use Unicode::Normalize;

my $root = new URI ('http://www.justice.gov.sk/Stranky/Ministerstvo/Vyberove-konania-v-rezorte/Zoznam-vyberovych-konani.aspx');
my $mech = new WWW::Mechanize;
my $dt = new Database::DumpTruck ({ dbname => 'data.sqlite', table => 'swdata' });

sub do_detail
{
	my $resp = shift;

	my $tree = new_from_content HTML::TreeBuilder ($resp->decoded_content);

	# This is what we deal with:
	#
	# <div  class="DetailTable">
	#     <div class="popiska">Organizácia:</div>
	#     <div class="hodnota">Okresný súd Košice I</div>
	#     <div class="riadok"></div>
	# 
	#     <div class="popiska">Pozícia:</div>
	#     <div class="hodnota">absolvenská prax</div>
	#     <div class="riadok"></div>
	# ...
	#     <div class="skupina">Prehľad prihlásených uchádzačov:</div>
	#     <div class="riadok ciara"></div>
	# 
	#     <div>
	# 
	# </div>
	# </div>

	my ($table) = $tree->look_down (class => 'DetailTable');
	my @divs = $table->look_down (_tag => 'div');

	my %row;
	my $popiska = '';
	my $popiska_db = '';
	my $hodnota = '';

	foreach my $div (@divs) {
		my $class = ($div->attr('class') || '');

		if ($class eq 'popiska') {
			$popiska = $div->as_trimmed_text;

			# Beautify a bit!
			$popiska =~ s/:$//;

			# Remove diacritics and remove spaces and slashes
			# so we can use data from page to create columns
			$popiska_db = NFKD($popiska);
			$popiska_db =~ s/\p{NonspacingMark}//g;
			$popiska_db =~ s/[ \/]/_/g;
		} elsif ($class eq 'hodnota') {
			$hodnota = $div->as_trimmed_text;

			# Is the value a link? Absolutize it!
			my ($link) = @{$div->extract_links ('a')};
			$hodnota = new URI ($link->[0])->abs ($resp->request->uri)->as_string
				if $link;

			if ($hodnota ne '') {
				$row{$popiska_db} = $hodnota;
			}

			$popiska = '';
			$popiska_db = '';
			$hodnota = '';
		}
	}

	print $row{"Datum_uzavierky"} . "\n";

	$dt->upsert (\%row);
}

# Roll!
$mech->get ($root);
do {
	
	do_detail ($mech->clone->get ($_)) foreach
		$mech->find_all_links (url_regex => qr/Detail-vyberoveho-konania.aspx/);

	# The pager element. Retarded.
	my ($pager) = $mech->find_all_inputs (name_regex => qw/cmbAGVPager$/);
	$pager->value ($pager->value + 1);

	# Page still valid?
	if (grep { $_ == $pager->value } $pager->possible_values) {
		$mech->submit_form;
	} else {
		# Destroy the agent, we're done.
		$mech = undef;
	}
} while ($mech);

$dt->create_index(['Vyhlasenie_konania'], undef, 'IF NOT EXISTS', 'UNIQUE');
