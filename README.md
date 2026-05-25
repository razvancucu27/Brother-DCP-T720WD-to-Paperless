Changes:
- brscan5 instead of brscan4
- stdout redirect instead of --output-file
- 3s delay before scan
- --source FlatBed support

INFO:
Change source from Flatbead to ADF

In /etc/brother-scan-to-paperless/config.json change:
json"source": "FlatBed",
to:
json"source": "Automatic Document Feeder(left aligned)",
Then restart the daemon:
bashsystemctl restart brother-scan-to-paperless

Install: 

wget -O install.sh https://raw.githubusercontent.com/razvancucu27/Brother-DCP-T720WD-to-Paperless/main/install.sh && chmod +x install.sh && nano install.sh && bash install.sh
