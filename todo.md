Hoe kan het dat bij het rippen van ~/ister/SEINFELD_S4_D1.iso dit programma ~/ister/disc_ripper/output/seinfel_s4_d1/title_02_angle2.mkv makemkv /home/gerben/Video's/dvd1/Seinfeld - Season 4 (Disc 1)-B1_t02.mkv De disk bevat wel een kras. Het lijkt er op dat makemkv daar om heen werkt.
- Seinfeld s08d1 ook kapot



Verbeteren met snelheid/efficentie van scannnen. Nu lijkt die meerdere keren het zelfde te scanen.

Als de gebruiker de params naar mkvextract en subtitle-ocr heeft mee gegeven bij he runnen van de applicatie of als ze op de /usr/bin folder staan. Met mkvextract en subtitle-ocr zoals in /home/gerben/ister/server/disk/src/main/java/app/ister/disk/events/mediafilefound/MediaFileFoundExtractSubtitles.java de subtitles kunnnen extracten. Dan een externe srt file aanmaken. Met dezelfde naam als video file, maar dan video_file.en.srt dus andere extensie en taal er bij. Dit is optioneel dus moet apart gevraagd worden of de gebruiker dit wilt na de stap als die gevraagd is of die de namen van de tracks wilt aanpassen.

Het moet mogelijk zijn om video's direct goed te noemen. Dus na het scherm dat de gebruiker de items van de disc kan selecteren moet gevraagd worden hoe die het item op schijf moet heten. Eerst vragen of die die handmatig wilt zetten. Zo ja allemaal langs gaan. En een default zetten netzoals bij alle andere vragen.
Als de gebruiker in de start params een themoviedb token en settings voor een llm geeft (Ook moeten de tool mkvextract en subtitle-ocr net zoals bij het extracten van subtitles aanwezig zijn. Hoe mag de subtitles van die stap gebruiken, maar als de gebruiker niet die subtitles wilt, moet die de subtitles maken, maar verwijdern op het eind.) de optie gegeven worden om een vragenteken kunnen antwoorden, behalve als de video geen subtitles bevat. Als dat het geval is moet er aan een llm gevraagd worden hoe de film/serie te vinden. Dit aan de hand met de gegeneerden subtitles en de naam van de disc. Dan de requesten doen naar de tmdb. Als het een film is dan het bestand "FILM NAME (YEAR).mkv" noemen. Is het een serie de descriptions van de afleveringen aan de llm geven en vragen welke aflvering het kan zijn. Dan de episode noemen "s01e01.mkv". Wordt er niks gevonden dan gewoon de oude default naam gebruiken.

Flutter responsive frontend.
- In de frontend moet alle functionaliteit zitten die ook in de cli app zit.
- De frontend is geplists links de disks en rechts info over de geklikte disk (in een kleinde width scherm moet als er in het linker panel geklikt worden over gegaan naar het rechter panel en de links boven een terug knop.)
- Een frontend waar links een list staat met alle disks plus een mogelijkheid om iso toetevoegen. 
  - Dit zijn listtile waar je de info ziet zoals in het "Available drives" cli. 
  - Er moet op het eind eject knop kijken als er een disc avaible is, behalve als die aan het rippen is, dan moet er een loading icon staan.
- Als er op een drive wordt geklikt moet die rechts verschijnen.
- Niks mag de gui laten hangen. Altijd iets tonen en graag met skelotinizer werken.
- Er moet ook een settings menu zijn. Deze moet de confing in de xdg map kunnen aanpassen.

Graag de auto selecter verbeteren. Bijvoorbeeld bij deze verwacht ik het volgende 2.1 2.2 2.3 2.4 2.5 2.6 en niet 7.1:
gerben@cyanea:~/ister/disc_ripper$ dart run bin/rip.dart -d /dev/sr2 --name Seinfeld --season 7
Disc type: dvd
Device:    /dev/sr2
Output:    /home/gerben/ister/disc_ripper/output
ffmpeg:    ffmpeg

Disc:  SEINFELD_SEASON_7_DISC3
Titles found (VIDEO_TS): 14

Available titles:
1: 00:22:07  4 audio  19 sub   5 ch
2: 00:42:27  4 audio  19 sub   7 ch
3: 00:22:07  4 audio  19 sub   5 ch
4: 00:22:09  4 audio  19 sub   5 ch
5: 00:22:09  4 audio  19 sub   5 ch
6.1: 00:11:46  1 audio   4 sub   3 ch  (angle 1/3)
6.2: 00:03:32  1 audio   4 sub   2 ch  (angle 2/3)
6.3: 00:08:14  1 audio   4 sub   2 ch  (angle 3/3)
7.1: 00:06:44  1 audio   4 sub   5 ch  (angle 1/4)
7.2: 00:00:40  1 audio   4 sub   2 ch  (angle 2/4)
7.3: 00:01:00  1 audio   4 sub   2 ch  (angle 3/4)
7.4: 00:03:55  1 audio   4 sub   2 ch  (angle 4/4)
8: 00:01:09  1 audio   4 sub   2 ch
9: 00:00:14  1 audio   0 sub   2 ch
10.2: 00:00:10  1 audio   0 sub   1 ch  (angle 2/13)
10.3: 00:00:10  1 audio   0 sub   1 ch  (angle 3/13)
10.4: 00:00:12  1 audio   0 sub   1 ch  (angle 4/13)
10.5: 00:00:32  1 audio   0 sub   1 ch  (angle 5/13)
10.7: 00:00:10  1 audio   0 sub   1 ch  (angle 7/13)
10.8: 00:00:10  1 audio   0 sub   1 ch  (angle 8/13)
10.9: 00:00:10  1 audio   0 sub   1 ch  (angle 9/13)
10.10: 00:00:10  1 audio   0 sub   1 ch  (angle 10/13)
10.11: 00:00:10  1 audio   0 sub   1 ch  (angle 11/13)
10.12: 00:00:10  1 audio   0 sub   1 ch  (angle 12/13)
11.1: 00:00:06  1 audio   0 sub   1 ch  (angle 1/11)
11.2: 00:00:06  1 audio   0 sub   1 ch  (angle 2/11)
11.3: 00:00:06  1 audio   0 sub   1 ch  (angle 3/11)
11.4: 00:00:06  1 audio   0 sub   1 ch  (angle 4/11)
11.5: 00:00:06  1 audio   0 sub   1 ch  (angle 5/11)
11.6: 00:00:06  1 audio   0 sub   1 ch  (angle 6/11)
11.7: 00:00:06  1 audio   0 sub   1 ch  (angle 7/11)
11.8: 00:00:06  1 audio   0 sub   1 ch  (angle 8/11)
11.9: 00:00:06  1 audio   0 sub   1 ch  (angle 9/11)
11.10: 00:00:06  1 audio   0 sub   1 ch  (angle 10/11)
12.1: 00:00:09  1 audio   0 sub   2 ch  (angle 1/5)
12.2: 00:00:09  1 audio   0 sub   2 ch  (angle 2/5)
12.3: 00:00:09  1 audio   0 sub   2 ch  (angle 3/5)
12.4: 00:00:09  1 audio   0 sub   2 ch  (angle 4/5)
12.5: 00:00:09  1 audio   0 sub   2 ch  (angle 5/5)
13.1: 00:00:10  2 audio   1 sub   1 ch  (angle 1/77)
13.2: 00:00:39  2 audio   1 sub   1 ch  (angle 2/77)
13.3: 00:00:17  2 audio   1 sub   1 ch  (angle 3/77)
13.4: 00:00:35  2 audio   1 sub   1 ch  (angle 4/77)
13.5: 00:00:19  2 audio   1 sub   1 ch  (angle 5/77)
13.6: 00:00:19  2 audio   1 sub   1 ch  (angle 6/77)
13.7: 00:00:19  2 audio   1 sub   1 ch  (angle 7/77)
13.8: 00:00:19  2 audio   1 sub   1 ch  (angle 8/77)
13.9: 00:00:19  2 audio   1 sub   1 ch  (angle 9/77)
13.10: 00:00:19  2 audio   1 sub   1 ch  (angle 10/77)
13.11: 00:00:32  2 audio   1 sub   1 ch  (angle 11/77)
13.12: 00:00:37  2 audio   1 sub   1 ch  (angle 12/77)
13.13: 00:00:27  2 audio   1 sub   1 ch  (angle 13/77)
13.14: 00:00:48  2 audio   1 sub   1 ch  (angle 14/77)
13.15: 00:01:39  2 audio   1 sub   1 ch  (angle 15/77)
13.16: 00:01:08  2 audio   1 sub   1 ch  (angle 16/77)
13.17: 00:01:19  2 audio   1 sub   1 ch  (angle 17/77)
13.18: 00:01:02  2 audio   1 sub   1 ch  (angle 18/77)
13.19: 00:01:26  2 audio   1 sub   1 ch  (angle 19/77)
13.20: 00:00:32  2 audio   1 sub   1 ch  (angle 20/77)
13.21: 00:00:45  2 audio   1 sub   1 ch  (angle 21/77)
13.22: 00:01:07  2 audio   1 sub   1 ch  (angle 22/77)
13.23: 00:00:31  2 audio   1 sub   1 ch  (angle 23/77)
13.24: 00:00:45  2 audio   1 sub   1 ch  (angle 24/77)
13.25: 00:00:32  2 audio   1 sub   1 ch  (angle 25/77)
13.26: 00:01:30  2 audio   1 sub   1 ch  (angle 26/77)
13.27: 00:00:36  2 audio   1 sub   1 ch  (angle 27/77)
13.28: 00:00:53  2 audio   1 sub   1 ch  (angle 28/77)
13.29: 00:00:24  2 audio   1 sub   1 ch  (angle 29/77)
13.30: 00:01:48  2 audio   1 sub   1 ch  (angle 30/77)
13.31: 00:01:02  2 audio   1 sub   1 ch  (angle 31/77)
13.32: 00:23:28  2 audio   1 sub  21 ch  (angle 32/77)
13.33: 00:00:17  2 audio   1 sub   1 ch  (angle 33/77)
13.34: 00:00:17  2 audio   1 sub   1 ch  (angle 34/77)
13.35: 00:00:17  2 audio   1 sub   1 ch  (angle 35/77)
13.36: 00:00:17  2 audio   1 sub   1 ch  (angle 36/77)
13.37: 00:00:17  2 audio   1 sub   1 ch  (angle 37/77)
13.38: 00:00:17  2 audio   1 sub   1 ch  (angle 38/77)
13.39: 00:00:17  2 audio   1 sub   1 ch  (angle 39/77)
13.40: 00:00:17  2 audio   1 sub   1 ch  (angle 40/77)
13.41: 00:00:17  2 audio   1 sub   1 ch  (angle 41/77)
13.42: 00:00:17  2 audio   1 sub   1 ch  (angle 42/77)
13.43: 00:00:17  2 audio   1 sub   1 ch  (angle 43/77)
13.44: 00:00:17  2 audio   1 sub   1 ch  (angle 44/77)
13.45: 00:00:17  2 audio   1 sub   1 ch  (angle 45/77)
13.46: 00:00:17  2 audio   1 sub   1 ch  (angle 46/77)
13.47: 00:00:17  2 audio   1 sub   1 ch  (angle 47/77)
13.48: 00:00:17  2 audio   1 sub   1 ch  (angle 48/77)
13.49: 00:00:17  2 audio   1 sub   1 ch  (angle 49/77)
13.50: 00:00:17  2 audio   1 sub   1 ch  (angle 50/77)
13.51: 00:00:17  2 audio   1 sub   1 ch  (angle 51/77)
13.52: 00:00:17  2 audio   1 sub   1 ch  (angle 52/77)
13.53: 00:00:17  2 audio   1 sub   1 ch  (angle 53/77)
13.54: 00:00:17  2 audio   1 sub   1 ch  (angle 54/77)
13.77: 00:00:10  2 audio   1 sub   1 ch  (angle 77/77)
14.1: 00:00:10  2 audio   1 sub   1 ch  (angle 1/77)
14.2: 00:00:39  2 audio   1 sub   1 ch  (angle 2/77)
14.3: 00:00:17  2 audio   1 sub   1 ch  (angle 3/77)
14.4: 00:00:35  2 audio   1 sub   1 ch  (angle 4/77)
14.5: 00:00:19  2 audio   1 sub   1 ch  (angle 5/77)
14.6: 00:00:19  2 audio   1 sub   1 ch  (angle 6/77)
14.7: 00:00:19  2 audio   1 sub   1 ch  (angle 7/77)
14.8: 00:00:19  2 audio   1 sub   1 ch  (angle 8/77)
14.9: 00:00:19  2 audio   1 sub   1 ch  (angle 9/77)
14.10: 00:00:19  2 audio   1 sub   1 ch  (angle 10/77)
14.11: 00:00:32  2 audio   1 sub   1 ch  (angle 11/77)
14.12: 00:00:37  2 audio   1 sub   1 ch  (angle 12/77)
14.13: 00:00:27  2 audio   1 sub   1 ch  (angle 13/77)
14.14: 00:00:48  2 audio   1 sub   1 ch  (angle 14/77)
14.15: 00:01:39  2 audio   1 sub   1 ch  (angle 15/77)
14.16: 00:01:08  2 audio   1 sub   1 ch  (angle 16/77)
14.17: 00:01:19  2 audio   1 sub   1 ch  (angle 17/77)
14.18: 00:01:02  2 audio   1 sub   1 ch  (angle 18/77)
14.19: 00:01:26  2 audio   1 sub   1 ch  (angle 19/77)
14.20: 00:00:32  2 audio   1 sub   1 ch  (angle 20/77)
14.21: 00:00:45  2 audio   1 sub   1 ch  (angle 21/77)
14.22: 00:01:07  2 audio   1 sub   1 ch  (angle 22/77)
14.23: 00:00:31  2 audio   1 sub   1 ch  (angle 23/77)
14.24: 00:00:45  2 audio   1 sub   1 ch  (angle 24/77)
14.25: 00:00:32  2 audio   1 sub   1 ch  (angle 25/77)
14.26: 00:01:30  2 audio   1 sub   1 ch  (angle 26/77)
14.27: 00:00:36  2 audio   1 sub   1 ch  (angle 27/77)
14.28: 00:00:53  2 audio   1 sub   1 ch  (angle 28/77)
14.29: 00:00:24  2 audio   1 sub   1 ch  (angle 29/77)
14.30: 00:01:48  2 audio   1 sub   1 ch  (angle 30/77)
14.31: 00:01:02  2 audio   1 sub   1 ch  (angle 31/77)
14.32: 00:23:28  2 audio   1 sub  21 ch  (angle 32/77)
14.33: 00:00:17  2 audio   1 sub   1 ch  (angle 33/77)
14.34: 00:00:17  2 audio   1 sub   1 ch  (angle 34/77)
14.35: 00:00:17  2 audio   1 sub   1 ch  (angle 35/77)
14.36: 00:00:17  2 audio   1 sub   1 ch  (angle 36/77)
14.37: 00:00:17  2 audio   1 sub   1 ch  (angle 37/77)
14.38: 00:00:17  2 audio   1 sub   1 ch  (angle 38/77)
14.39: 00:00:17  2 audio   1 sub   1 ch  (angle 39/77)
14.40: 00:00:17  2 audio   1 sub   1 ch  (angle 40/77)
14.41: 00:00:17  2 audio   1 sub   1 ch  (angle 41/77)
14.42: 00:00:17  2 audio   1 sub   1 ch  (angle 42/77)
14.43: 00:00:17  2 audio   1 sub   1 ch  (angle 43/77)
14.44: 00:00:17  2 audio   1 sub   1 ch  (angle 44/77)
14.45: 00:00:17  2 audio   1 sub   1 ch  (angle 45/77)
14.46: 00:00:17  2 audio   1 sub   1 ch  (angle 46/77)
14.47: 00:00:17  2 audio   1 sub   1 ch  (angle 47/77)
14.48: 00:00:17  2 audio   1 sub   1 ch  (angle 48/77)
14.49: 00:00:17  2 audio   1 sub   1 ch  (angle 49/77)
14.50: 00:00:17  2 audio   1 sub   1 ch  (angle 50/77)
14.51: 00:00:17  2 audio   1 sub   1 ch  (angle 51/77)
14.52: 00:00:17  2 audio   1 sub   1 ch  (angle 52/77)
14.53: 00:00:17  2 audio   1 sub   1 ch  (angle 53/77)
14.54: 00:00:17  2 audio   1 sub   1 ch  (angle 54/77)
14.77: 00:00:10  2 audio   1 sub   1 ch  (angle 77/77)

Enter titles (comma- or space-separated, e.g.: 1 3.1 7),
or press Enter for suggestion [2]:

1 2 3 4 5

Kan je bij het autname van de episodes ook de gastrollen opnemen bij het checken? Dus als de tmdb gastrollen ziet dan moet de llm ook dat in de overweging mee nemen.








Eject disc? [y/N] gerben@cyanea:~/ister/disc_ripper$ dart run bin/rip.dart -i /dev/sr0 --name Seinfeld --season 7
Disc type: dvd
Device:    /dev/sr0
Output:    /home/gerben/ister/disc_ripper/output
ffmpeg:    ffmpeg

Disc:  SEINFELD_SEASON_7_DISC1
Titles found: 89

Available titles:
1: 00:22:56  4 audio  19 sub   4 ch
2: 00:22:10  4 audio  19 sub   4 ch
3: 00:22:07  4 audio  19 sub   4 ch
4: 00:22:01  4 audio  19 sub   4 ch
7.1: 00:16:17  1 audio   4 sub   3 ch  (angle 1/4)
7.2: 00:04:16  1 audio   4 sub   2 ch  (angle 2/4)
7.3: 00:04:25  1 audio   4 sub   2 ch  (angle 3/4)
7.4: 00:07:34  1 audio   4 sub   2 ch  (angle 4/4)
8.1: 00:04:07  1 audio   4 sub   3 ch  (angle 1/3)
8.2: 00:01:42  1 audio   4 sub   2 ch  (angle 2/3)
8.3: 00:02:25  1 audio   4 sub   2 ch  (angle 3/3)
9: 00:01:14  1 audio   4 sub   2 ch
10: 00:01:51  1 audio   4 sub   2 ch
11: 00:00:14  1 audio   0 sub   2 ch
12.2: 00:00:10  1 audio   0 sub   1 ch  (angle 2/13)
12.3: 00:00:10  1 audio   0 sub   1 ch  (angle 3/13)
12.4: 00:00:12  1 audio   0 sub   1 ch  (angle 4/13)
12.5: 00:00:32  1 audio   0 sub   1 ch  (angle 5/13)
12.7: 00:00:10  1 audio   0 sub   1 ch  (angle 7/13)
12.8: 00:00:10  1 audio   0 sub   1 ch  (angle 8/13)
12.9: 00:00:10  1 audio   0 sub   1 ch  (angle 9/13)
12.10: 00:00:10  1 audio   0 sub   1 ch  (angle 10/13)
12.11: 00:00:10  1 audio   0 sub   1 ch  (angle 11/13)
12.12: 00:00:10  1 audio   0 sub   1 ch  (angle 12/13)
13.1: 00:00:06  1 audio   0 sub   1 ch  (angle 1/11)
13.2: 00:00:06  1 audio   0 sub   1 ch  (angle 2/11)
13.3: 00:00:06  1 audio   0 sub   1 ch  (angle 3/11)
13.4: 00:00:06  1 audio   0 sub   1 ch  (angle 4/11)
13.5: 00:00:06  1 audio   0 sub   1 ch  (angle 5/11)
13.6: 00:00:06  1 audio   0 sub   1 ch  (angle 6/11)
13.7: 00:00:06  1 audio   0 sub   1 ch  (angle 7/11)
13.8: 00:00:06  1 audio   0 sub   1 ch  (angle 8/11)
13.9: 00:00:06  1 audio   0 sub   1 ch  (angle 9/11)
13.10: 00:00:06  1 audio   0 sub   1 ch  (angle 10/11)
15.1: 00:00:10  2 audio   1 sub   1 ch  (angle 1/77)
15.2: 00:00:39  2 audio   1 sub   1 ch  (angle 2/77)
15.3: 00:00:17  2 audio   1 sub   1 ch  (angle 3/77)
15.4: 00:00:35  2 audio   1 sub   1 ch  (angle 4/77)
15.5: 00:00:19  2 audio   1 sub   1 ch  (angle 5/77)
15.6: 00:00:19  2 audio   1 sub   1 ch  (angle 6/77)
15.7: 00:00:19  2 audio   1 sub   1 ch  (angle 7/77)
15.8: 00:00:19  2 audio   1 sub   1 ch  (angle 8/77)
15.9: 00:00:19  2 audio   1 sub   1 ch  (angle 9/77)
15.10: 00:00:19  2 audio   1 sub   1 ch  (angle 10/77)
15.11: 00:00:32  2 audio   1 sub   1 ch  (angle 11/77)
15.12: 00:00:37  2 audio   1 sub   1 ch  (angle 12/77)
15.13: 00:00:27  2 audio   1 sub   1 ch  (angle 13/77)
15.14: 00:00:48  2 audio   1 sub   1 ch  (angle 14/77)
15.15: 00:01:39  2 audio   1 sub   1 ch  (angle 15/77)
15.16: 00:01:08  2 audio   1 sub   1 ch  (angle 16/77)
15.17: 00:01:19  2 audio   1 sub   1 ch  (angle 17/77)
15.18: 00:01:02  2 audio   1 sub   1 ch  (angle 18/77)
15.19: 00:01:26  2 audio   1 sub   1 ch  (angle 19/77)
15.20: 00:00:32  2 audio   1 sub   1 ch  (angle 20/77)
15.21: 00:00:45  2 audio   1 sub   1 ch  (angle 21/77)
15.22: 00:01:07  2 audio   1 sub   1 ch  (angle 22/77)
15.23: 00:00:31  2 audio   1 sub   1 ch  (angle 23/77)
15.24: 00:00:45  2 audio   1 sub   1 ch  (angle 24/77)
15.25: 00:00:32  2 audio   1 sub   1 ch  (angle 25/77)
15.26: 00:01:30  2 audio   1 sub   1 ch  (angle 26/77)
15.27: 00:00:36  2 audio   1 sub   1 ch  (angle 27/77)
15.28: 00:00:53  2 audio   1 sub   1 ch  (angle 28/77)
15.29: 00:00:24  2 audio   1 sub   1 ch  (angle 29/77)
15.30: 00:01:48  2 audio   1 sub   1 ch  (angle 30/77)
15.31: 00:01:02  2 audio   1 sub   1 ch  (angle 31/77)
15.32: 00:23:28  2 audio   1 sub  20 ch  (angle 32/77)
15.33: 00:00:17  2 audio   1 sub   1 ch  (angle 33/77)
15.34: 00:00:17  2 audio   1 sub   1 ch  (angle 34/77)
15.35: 00:00:17  2 audio   1 sub   1 ch  (angle 35/77)
15.36: 00:00:17  2 audio   1 sub   1 ch  (angle 36/77)
15.37: 00:00:17  2 audio   1 sub   1 ch  (angle 37/77)
15.38: 00:00:17  2 audio   1 sub   1 ch  (angle 38/77)
15.39: 00:00:17  2 audio   1 sub   1 ch  (angle 39/77)
15.40: 00:00:17  2 audio   1 sub   1 ch  (angle 40/77)
15.41: 00:00:17  2 audio   1 sub   1 ch  (angle 41/77)
15.42: 00:00:17  2 audio   1 sub   1 ch  (angle 42/77)
15.43: 00:00:17  2 audio   1 sub   1 ch  (angle 43/77)
15.44: 00:00:17  2 audio   1 sub   1 ch  (angle 44/77)
15.45: 00:00:17  2 audio   1 sub   1 ch  (angle 45/77)
15.46: 00:00:17  2 audio   1 sub   1 ch  (angle 46/77)
15.47: 00:00:17  2 audio   1 sub   1 ch  (angle 47/77)
15.48: 00:00:17  2 audio   1 sub   1 ch  (angle 48/77)
15.49: 00:00:17  2 audio   1 sub   1 ch  (angle 49/77)
15.50: 00:00:17  2 audio   1 sub   1 ch  (angle 50/77)
15.51: 00:00:17  2 audio   1 sub   1 ch  (angle 51/77)
15.52: 00:00:17  2 audio   1 sub   1 ch  (angle 52/77)
15.53: 00:00:17  2 audio   1 sub   1 ch  (angle 53/77)
15.54: 00:00:17  2 audio   1 sub   1 ch  (angle 54/77)
15.77: 00:00:10  2 audio   1 sub   1 ch  (angle 77/77)

Enter titles (comma- or space-separated, e.g.: 1 3.1 7),
or press Enter for suggestion [1 2 3 4]:



gerben@cyanea:~/ister/disc_ripper$ dart run bin/rip.dart -i /dev/sr1 --name Seinfeld --season 7
Disc type: dvd
Device:    /dev/sr1
Output:    /home/gerben/ister/disc_ripper/output
ffmpeg:    ffmpeg

Disc:  SEINFELD_SEASON_7_DISC2
Titles found: 90

Available titles:
1: 00:22:17  4 audio  19 sub   4 ch
2: 00:22:07  4 audio  19 sub   4 ch
4: 00:22:09  4 audio  19 sub   4 ch
7.1: 00:21:38  1 audio   4 sub   5 ch  (angle 1/6)
7.2: 00:02:38  1 audio   4 sub   2 ch  (angle 2/6)
7.3: 00:05:40  1 audio   4 sub   2 ch  (angle 3/6)
7.4: 00:03:47  1 audio   4 sub   2 ch  (angle 4/6)
7.5: 00:07:22  1 audio   4 sub   2 ch  (angle 5/6)
7.6: 00:02:11  1 audio   4 sub   2 ch  (angle 6/6)
8.1: 00:02:21  1 audio   4 sub   3 ch  (angle 1/3)
8.2: 00:00:50  1 audio   4 sub   2 ch  (angle 2/3)
8.3: 00:01:31  1 audio   4 sub   2 ch  (angle 3/3)
9: 00:15:31  1 audio   4 sub   1 ch
10: 00:02:40  1 audio   4 sub   2 ch
11: 00:00:14  1 audio   0 sub   2 ch
12.2: 00:00:10  1 audio   0 sub   1 ch  (angle 2/13)
12.3: 00:00:10  1 audio   0 sub   1 ch  (angle 3/13)
12.4: 00:00:12  1 audio   0 sub   1 ch  (angle 4/13)
12.5: 00:00:32  1 audio   0 sub   1 ch  (angle 5/13)
12.7: 00:00:10  1 audio   0 sub   1 ch  (angle 7/13)
12.8: 00:00:10  1 audio   0 sub   1 ch  (angle 8/13)
12.9: 00:00:10  1 audio   0 sub   1 ch  (angle 9/13)
12.10: 00:00:10  1 audio   0 sub   1 ch  (angle 10/13)
12.11: 00:00:10  1 audio   0 sub   1 ch  (angle 11/13)
12.12: 00:00:10  1 audio   0 sub   1 ch  (angle 12/13)
13.1: 00:00:06  1 audio   0 sub   1 ch  (angle 1/11)
13.2: 00:00:06  1 audio   0 sub   1 ch  (angle 2/11)
13.3: 00:00:06  1 audio   0 sub   1 ch  (angle 3/11)
13.4: 00:00:06  1 audio   0 sub   1 ch  (angle 4/11)
13.5: 00:00:06  1 audio   0 sub   1 ch  (angle 5/11)
13.6: 00:00:06  1 audio   0 sub   1 ch  (angle 6/11)
13.7: 00:00:06  1 audio   0 sub   1 ch  (angle 7/11)
13.8: 00:00:06  1 audio   0 sub   1 ch  (angle 8/11)
13.9: 00:00:06  1 audio   0 sub   1 ch  (angle 9/11)
13.10: 00:00:06  1 audio   0 sub   1 ch  (angle 10/11)
15.1: 00:00:10  2 audio   1 sub   1 ch  (angle 1/77)
15.2: 00:00:39  2 audio   1 sub   1 ch  (angle 2/77)
15.3: 00:00:17  2 audio   1 sub   1 ch  (angle 3/77)
15.4: 00:00:35  2 audio   1 sub   1 ch  (angle 4/77)
15.5: 00:00:19  2 audio   1 sub   1 ch  (angle 5/77)
15.6: 00:00:19  2 audio   1 sub   1 ch  (angle 6/77)
15.7: 00:00:19  2 audio   1 sub   1 ch  (angle 7/77)
15.8: 00:00:19  2 audio   1 sub   1 ch  (angle 8/77)
15.9: 00:00:19  2 audio   1 sub   1 ch  (angle 9/77)
15.10: 00:00:19  2 audio   1 sub   1 ch  (angle 10/77)
15.11: 00:00:32  2 audio   1 sub   1 ch  (angle 11/77)
15.12: 00:00:37  2 audio   1 sub   1 ch  (angle 12/77)
15.13: 00:00:27  2 audio   1 sub   1 ch  (angle 13/77)
15.14: 00:00:48  2 audio   1 sub   1 ch  (angle 14/77)
15.15: 00:01:39  2 audio   1 sub   1 ch  (angle 15/77)
15.16: 00:01:08  2 audio   1 sub   1 ch  (angle 16/77)
15.17: 00:01:19  2 audio   1 sub   1 ch  (angle 17/77)
15.18: 00:01:02  2 audio   1 sub   1 ch  (angle 18/77)
15.19: 00:01:26  2 audio   1 sub   1 ch  (angle 19/77)
15.20: 00:00:32  2 audio   1 sub   1 ch  (angle 20/77)
15.21: 00:00:45  2 audio   1 sub   1 ch  (angle 21/77)
15.22: 00:01:07  2 audio   1 sub   1 ch  (angle 22/77)
15.23: 00:00:31  2 audio   1 sub   1 ch  (angle 23/77)
15.24: 00:00:45  2 audio   1 sub   1 ch  (angle 24/77)
15.25: 00:00:32  2 audio   1 sub   1 ch  (angle 25/77)
15.26: 00:01:30  2 audio   1 sub   1 ch  (angle 26/77)
15.27: 00:00:36  2 audio   1 sub   1 ch  (angle 27/77)
15.28: 00:00:53  2 audio   1 sub   1 ch  (angle 28/77)
15.29: 00:00:24  2 audio   1 sub   1 ch  (angle 29/77)
15.30: 00:01:48  2 audio   1 sub   1 ch  (angle 30/77)
15.31: 00:01:02  2 audio   1 sub   1 ch  (angle 31/77)
15.32: 00:23:28  2 audio   1 sub  20 ch  (angle 32/77)
15.33: 00:00:17  2 audio   1 sub   1 ch  (angle 33/77)
15.34: 00:00:17  2 audio   1 sub   1 ch  (angle 34/77)
15.35: 00:00:17  2 audio   1 sub   1 ch  (angle 35/77)
15.36: 00:00:17  2 audio   1 sub   1 ch  (angle 36/77)
15.37: 00:00:17  2 audio   1 sub   1 ch  (angle 37/77)
15.38: 00:00:17  2 audio   1 sub   1 ch  (angle 38/77)
15.39: 00:00:17  2 audio   1 sub   1 ch  (angle 39/77)
15.40: 00:00:17  2 audio   1 sub   1 ch  (angle 40/77)
15.41: 00:00:17  2 audio   1 sub   1 ch  (angle 41/77)
15.42: 00:00:17  2 audio   1 sub   1 ch  (angle 42/77)
15.43: 00:00:17  2 audio   1 sub   1 ch  (angle 43/77)
15.44: 00:00:17  2 audio   1 sub   1 ch  (angle 44/77)
15.45: 00:00:17  2 audio   1 sub   1 ch  (angle 45/77)
15.46: 00:00:17  2 audio   1 sub   1 ch  (angle 46/77)
15.47: 00:00:17  2 audio   1 sub   1 ch  (angle 47/77)
15.48: 00:00:17  2 audio   1 sub   1 ch  (angle 48/77)
15.49: 00:00:17  2 audio   1 sub   1 ch  (angle 49/77)
15.50: 00:00:17  2 audio   1 sub   1 ch  (angle 50/77)
15.51: 00:00:17  2 audio   1 sub   1 ch  (angle 51/77)
15.52: 00:00:17  2 audio   1 sub   1 ch  (angle 52/77)
15.53: 00:00:17  2 audio   1 sub   1 ch  (angle 53/77)
15.54: 00:00:17  2 audio   1 sub   1 ch  (angle 54/77)
15.77: 00:00:10  2 audio   1 sub   1 ch  (angle 77/77)

Enter titles (comma- or space-separated, e.g.: 1 3.1 7),
or press Enter for suggestion [1 2 4]:

Ik had bij beide disc 6 titles verwacht, maar een kwam met 3 en de andere met 4. Zou je naar de disc's kunnen kijken en zorgen dat auto selecter correct de 6 aflevering selecteerd?









