
#!/bin/bash

./bin/ffmpeg -r 15 -vcodec mjpeg -f video4linux2 -s 960x544 -i /dev/video0  -tune zerolatency -preset ultrafast -r 30 -vbsf h264_mp4toannexb -vcodec h264 -f mpegts - | nc $1 8000
#./bin/ffmpeg -r 15 -vcodec mjpeg -f video4linux2 -s 960x544 -i /dev/video0 -vf scale=400:-1 -tune zerolatency -preset ultrafast -r 30 -vbsf h264_mp4toannexb -vcodec h264 -f mpegts - | nc $1 8000
