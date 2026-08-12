
gerben@cyanea:~/ister/disc_ripper$ dart run bin/rip.dart -i /dev/sr1
Disc type: dvd
Device:    /dev/sr1
Output:    /home/gerben/ister/disc_ripper/output
ffmpeg:    ffmpeg

Disc:  VICTORIOUS_S2_D1
Titles found: 7

Available titles:
6.1: 02:44:16  1 audio   0 sub   7 ch  (angle 1/12)
6.2: 00:23:37  1 audio   0 sub   2 ch  (angle 2/12)
6.3: 00:23:37  1 audio   0 sub   2 ch  (angle 3/12)
6.4: 00:46:09  1 audio   0 sub   2 ch  (angle 4/12)
6.5: 00:23:37  1 audio   0 sub   2 ch  (angle 5/12)
6.6: 00:23:38  1 audio   0 sub   2 ch  (angle 6/12)
6.7: 00:23:38  1 audio   0 sub   2 ch  (angle 7/12)


Hij laat geen subtitles zien, maar na het rippen zijn er vier subtitle tracks. Bij het rippen met makemkv laat die wel keurig een subtitle track zien en ript die ook.
Na het rippen is maar een subtitle track werkend de rest laat niks zien. Ook is het slect leesbare tekst die van makemkv is veel leesbaarder.
Kan je naar de disc kijken. Naar de makemkv output: /home/gerben/Video's/dvd1/C1_t01.mkv en eigen output: /home/gerben/ister/disc_ripper/output/VICTORIOUS_S2_D1/VICTORIOUS_S2_D1-title_06_angle2.mkv
Makemkv noemt de subtitless:
Track informatie
Type: Ondertitels
Taal: English
Codec: Closed Captions → Text
Output format: Text subtitles ( Lossy conversion )


































Dit waren je laaste aanpassingen.

● Here's a summary of what was implemented:

New file: lib/src/subtitles/cc_extractor.dart
- CcExtractor class: pipes the video track from an MKV through ffmpeg (-f mpeg2video) and streams the raw MPEG-2 bytes to a scanner
- _Mpeg2Scanner: sliding-window MPEG-2 parser that finds GOP timecodes and CC user_data packets
- _Eia608Decoder: EIA-608 pop-on caption decoder → SRT output
- Parses the actual DVS 053 format: count byte + ATSC A/53 triples where 0xFF type triples carry the EIA-608 pairs (non-standard   
  but used by all SD-DVD encoders)

Modified lib/src/rippers/dvd_ripper.dart
- Added _extractClosedCaptions() helper called after each successful rip
- Runs CC extraction only for NTSC titles (videoHeight == 480) with no IFO-declared subtitle tracks

Modified lib/src/models/dvd_title.dart
- Added mayHaveCc getter: true for NTSC titles with no IFO subs

Modified bin/rip.dart
- Title listing now shows CC instead of  0 sub for NTSC CC-only titles

The output matches MakeMKV's subtitle content exactly; timestamps differ by ~300ms (GOP-level vs frame-level) which is acceptable
for subtitle display.

Nu staan de subtitles nog steeds hetzelfde in het uiteindelijk bestand. Zou je nog een keer naar de bestanden en disc willen kijken? Ik verwacht dat het output besatand netzoals bij makemkv correct in de mkv file zitten dus 1 track en niet zoals niet 4 tracks.
Waarvan de eerste track ook subitles bevat die een zwarte achtergrond hebben ipv zoals bij makemkv doorzichtige achtergrond.
Naar de makemkv output: /home/gerben/Video's/dvd1/C1_t01.mkv en eigen output: /home/gerben/ister/disc_ripper/output/VICTORIOUS_S2_D1/VICTORIOUS_S2_D1-title_06_angle2.mkv

gerben@cyanea:~/ister/disc_ripper$ dart run bin/rip.dart -i /dev/sr1
Disc type: dvd
Device:    /dev/sr1
Output:    /home/gerben/ister/disc_ripper/output
ffmpeg:    ffmpeg

Disc:  VICTORIOUS_S2_D1
Titles found: 7

Available titles:
6.1: 02:44:16  1 audio  CC   7 ch  (angle 1/12)
6.2: 00:23:37  1 audio  CC   2 ch  (angle 2/12)
6.3: 00:23:37  1 audio  CC   2 ch  (angle 3/12)
6.4: 00:46:09  1 audio  CC   2 ch  (angle 4/12)
6.5: 00:23:37  1 audio  CC   2 ch  (angle 5/12)
6.6: 00:23:38  1 audio  CC   2 ch  (angle 6/12)
6.7: 00:23:38  1 audio  CC   2 ch  (angle 7/12)

Enter titles (comma- or space-separated, e.g.: 1 3.1 7),
or press Enter for suggestion [6.2 6.3 6.4 6.5 6.6 6.7]:
6.6

Rename items? [y/N]
Extract subtitles to SRT? [y/N]
── Languages: title 6.6 [00:23:38]
Current languages:
Audio 1 (AC3 Stereo): eng
Set languages manually? [y/N]

(libdvdread available — CSS decryption active if applicable)
── Ripping: 6.6 → /home/gerben/ister/disc_ripper/output/VICTORIOUS_S2_D1/VICTORIOUS_S2_D1-title_06_angle6.mkv
libdvdread: Attempting to retrieve all CSS keys
libdvdread: This can take a _long_ time, please be patient
libdvdread: Get key for /VIDEO_TS/VIDEO_TS.VOB at 0x00000242
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_01_0.VOB at 0x00036ff1
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_01_1.VOB at 0x00037531
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_02_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_02_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_03_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_03_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_04_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_04_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_05_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_05_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_06_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_06_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_07_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_07_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_08_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_08_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_09_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_09_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_10_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_10_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_11_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_11_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_12_0.VOB at 0x0003780a
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_12_1.VOB at 0x00037b09
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_13_0.VOB at 0x003cac17
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_13_1.VOB at 0x003cacba
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_14_0.VOB at 0x003cb301
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_14_1.VOB at 0x003cb3a4
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_15_0.VOB at 0x003cb4e2
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_15_1.VOB at 0x003cb596
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_16_0.VOB at 0x003cb65b
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_16_1.VOB at 0x003cb6fe
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_17_0.VOB at 0x003d1316
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_17_1.VOB at 0x003d13b9
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_18_0.VOB at 0x003d17ad
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_18_1.VOB at 0x003d1850
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_19_0.VOB at 0x003d1ba1
libdvdread: Elapsed time 0
libdvdread: Get key for /VIDEO_TS/VTS_19_1.VOB at 0x003d1c44
libdvdread: Elapsed time 0
libdvdread: Found 19 VTS's
libdvdread: Elapsed time 0
00:23:29  11.1x   [vist#0:1/mpeg2video @ 0x55f9e75d5ac0] timestamp discontinuity (stream id=480): -1419284534, new offset= 1419284534
[aist#0:2/ac3 @ 0x55f9e75d5c40] timestamp discontinuity (stream id=128): 1419316533, new offset= -31999

00:23:39  11.1x   
Done: /home/gerben/ister/disc_ripper/output/VICTORIOUS_S2_D1/VICTORIOUS_S2_D1-title_06_angle6.mkv
Scanning video stream for EIA-608 closed captions…
CC subtitle written → /home/gerben/ister/disc_ripper/output/VICTORIOUS_S2_D1/VICTORIOUS_S2_D1-title_06_angle6.en.srt

Eject disc? [y/r/N]  (r = load next disc):








Zou je de indeling kunnen veranderen. Ik wil graag drie verschillende projecten. disc_buddy_lib, disc_buddy_cli en disc_buddy_ui. cli en ui mogen depedencies hebben naar lib maar niet naar elkaar en lib moet compleet onafhankelijk zij van de rest.
Graag zo min mogelijk duplicated code

De add MKV moet ook support hebben voor directories net zoals de cli heeft. Graag ook een knop dus niet apart iso / mkv / dir.

Gemounte iso / mkv / dir moet als er op de eject knop geklikt worden verwijderd worden in de frontend.

In het disc menu ook een checkbox toevoegen met auto name. Deze box moet voor de serie season boxes zijn. Zodra die box gechecked is, moet pas die andere input velden invulbaar worden. 
Deze moet standaard staan zoals in de config.json staat, maar kan hier dus tijdelijk overschreven worden.

Graag naast de track title in de disc menu. Een mogelijkheid om de audio en subtitle tracks te selecteren en het hernoemen van tracks.

Links naast de rip knop ook een optie om de subtitle tracks te exporten.

In het settings menu onderaan een lijst met warnings voor welke functionaliteit niet werkt, wegens het ontbreken van depedencies.

De skelenotizer van de disc page lijkt niet echt op de daadwerkelijke pagina graag update zodat wel het geval is.