#!/bin/bash

./bin/ffmpeg -i $1 -f mpegts - | nc 127.0.0.1 8000 | mplayer -
