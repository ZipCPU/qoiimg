## An All-Verilog Implementation of the "Quite-OK Image Format"

The full format description can be found
[here](https://qoiformat.org/qoi-specification.pdf).

This repository currently consists of a QOI [encoder](rtl/qoi_encoder.v)
implementation.  This includes the file header,
[image compression](rtl/qoi_compress.v), and trailer.  The result of this
encoder is an AXI stream of video image "packets".  A Wishbone
[recorder](rtl/qoi_recorder.v) can be used to record these packets to memory.
The [recorder](rtl/qoi_recorder.v) requires components from the
[ZipCPU](https://github.com/ZipCPU)'s DMA at present.

A separate [decoder](rtl/qoi_decoder.v) is also planned to decode and
decompress images, but it remains in the early stages of its development.

## Back story

The purpose of this implementation is simply to minimize the bandwidth required
to store video images in memory.

Let me back up.  I have a SONAR project that can (currently) display some
amazing things to the HDMI output--in simulation.  In hardware, the displays are
all messed up.  Therefore, I need something that can capture the display output
to memory, so that I can then come back later and debug what was actually going
to the display.  The problem I have is that the memory bandwidth is already well
used--I don't want to take up any more of it, or risk any more of the design
failing due to memory latencies.  Therefore, the memory compression needs to
be quick.

Many of these SONAR images consist of [plots or other
charts](https://github.com/ZipCPU/vgasim/tree/dev/rtl/gfx) on a black
background.  QOI's run-length compression should make quick work of this black
background.  Likewise, the images often contain only a small number of colors,
such as the white lines.  Again, the image compression might note the white
pixel initially, but then ever after the white pixel(s) will be compressed to
a single byte of white, followed by a single byte of black, followed by a run of
black.  Again, this should compress quite well, reducing the bandwidth to memory
required by the algorithm.

## Implementation notes

**Project Goal**: real-time compression and decompression.  I think I've
figured out how to map the compression component to hardware.  The
decompression algorithm isn't there yet.  (i.e., it has known bugs) Neither
algorithm has been properly verified (yet).

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

This IP is currently a work-in-progress.  The encoder is hardware proven.  The
decoder passes a simulation test.

The current (and planned) components of this repository include:

- [qoi_compress](rtl/qoi_compress.v) compresses pixel data.  This
  critical component has now been formally verified.

  Although QOI supports an alpha channel, this compression engine does not
  (yet) support any alpha channels.

- [qoi_encoder](rtl/qoi_encoder.v) wraps the compression algorithm, providing
  both a file header containing image width and height, as well as an
  image trailer.

- [qoi_recorder](rtl/qoi_recorder.v) wraps the [QOI encoder](rtl/qoi_encoder.v)
  so that an entire image stream may be encoded and a fixed number of images
  may be copied to memory.  This recording capability depends upon both the
  [RXGears](https://github.com/ZipCPU/zipcpu/blob/master/rtl/zipdma/zipdma_rxgears.v) and the
  [S2MM](https://github.com/ZipCPU/zipcpu/blob/master/rtl/zipdma/zipdma_s2mm.v)
  components of the ZipDMA, both found in the
  [ZipCPU's git repository](https://github.com/ZipCPU/zipcpu).

- [qoi_decompress](rtl/qoi_decompress.v) is designed to decompress QOI encoded
  pixel data.  At present, this component passes an ad-hoc simulation check.

- [qoi_decoder](rtl/qoi_decoder.v) is designed to decompress QOI frames (files).
  It removes the header and trailer, detects the width and height, and
  produces a one-frame AXI video stream as an output.  This component is
  also part of the same ad-hoc simulation check used by other components.

- [qoi_framebuffer]() is not yet written.  Once written, this component will
  repeatedly read QOI image files from memory, and feed them to the decoder.
  The result (should) be a proper video stream once completed.  For now, this
  component is nothing more than vaporware.

## Simulation

A simulation model now exists that can compress a PNG file, decompress the
compressed stream, and then compare the result to the original PNG file.  This
model has now been successful over the course of many tests.  It still needs
some minor upgrades to make this simulation testing automatic in order to
support proper regression testing.

## License

This IP is available under GPLv3.  Other licenses may be available for purchase.

