#!/bin/bash

./bin/ffmpeg -i $1 -vf scale=400:trunc\(ow\/a\/2\)*2 -tune zerolatency -preset ultrafast -r 30 -vbsf h264_mp4toannexb -vcodec h264 -y -re -f mpegts - | nc $2 8000
