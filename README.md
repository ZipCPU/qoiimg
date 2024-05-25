## An All-Verilog Implementation of the "Quite-OK Image Format"

The full format description can be found
[here](https://qoiformat.org/qoi-specification.pdf).

This repository consists of both a [compression](rtl/qoi_compress.v) and
(eventually) a decompression implementation.

The [encoder](rtl/qoi_encoder.v) implementations file header, compression,
and trailer.  As a result, the incoming video stream is encoded into QOI
image "packets".

## Back story

The purpose of this implementation is simply to minimize the bandwidth
required to store video images in memory.

Let me back up.  I have a SONAR project that can (currently) display some
amazing things to the HDMI output--in simulation.  In hardware, the displays
are all messed up.  Therefore, I need something that can capture the display
output to memory, so that I can then come back later and debug what was
actually going to the display.  The problem I have is that the memory bandwidth
is already well used--I don't want to take up any more of it, or risk any
more of the design failing due to memory latencies.  Therefore, the memory
compression needs to be quick.

Many of these SONAR images consist of plots or other charts on a black
background.  QOI's run-length compression should make quick work of this
black background, turning it into a proper run length compression.  Likewise,
the images often contain plots of white lines on a black background.  Again,
the image compression might note the white pixel initially, but then ever after
the white pixel(s) will be compressed to a single byte of white, followed by
a single byte of black, followed by a run of black.  Again, this should
compress quite well, reducing the bandwidth to memory required by the
algorithm.

## Implementation notes

Goal: real-time compression and decompression.  I think I've figured out how
to map the compression component to hardware.  The decompression algorithm
isn't there yet.  (i.e., it has known bugs) Neither algorithm has been
properly verified (yet).

The trick in this implementation is getting the compression table, a block RAM
memory, to the point where it can be accessed in one cycle.  This means that
the table index must be calculated ahead of time, and the multiplications
before that.  This necessitates a pipeline operation, which is provided in
the image.  At present, this pipeline is 5-stages deep for compression.
Key to this operation are the two clock cycles required prior to the compression
table lookup.

Decoding is a bit more of a challenge, particularly since the compression
table address may depend upon a previous pixel's value--even before we know
the index of that previous pixel in the table.  Hence, a table lookup followed
by an offset value would require calculating the pixel offset prior to the
table lookup.  While I think I have this challenge solved, other issues
remain.

## Status

This IP is currently a work-in-progress.  The encoder/recorder currently passes
a simulation test as part of a larger project.  However, it doesn't yet have
its own regression suite--either simulation or formal verification based.
It hasn't seen hardware either.

One step at a time.

## License

This IP is available under GPLv3.  Other licenses may be available for
purchase.

