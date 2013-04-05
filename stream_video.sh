#!/bin/bash

./bin/ffmpeg -i $1 -vf scale=400:-1 -preset ultrafast -vbsf h264_mp4toannexb -vcodec h264 -f mpegts - | nc $2 8000
