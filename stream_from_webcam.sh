
#!/bin/bash

# crazy scale is to make sure the height is divisible by 2
./bin/ffmpeg -r 15 -vcodec mjpeg -f video4linux2 -s 960x544 -i /dev/video0 -vf scale=400:trunc\(ow\/a\/2\)*2 -tune zerolatency -preset ultrafast -r 30 -vbsf h264_mp4toannexb -vcodec h264 -y -re -f mpegts - | nc $1 8000
