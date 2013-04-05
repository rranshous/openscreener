
#!/bin/bash

./bin/ffmpeg -f video4linux2 -s 1280x720 -i /dev/video0 -vf scale=400:-1 -preset ultrafast -r 30 -f mpegts - | nc $1 8000
