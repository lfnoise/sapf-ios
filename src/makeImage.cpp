//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Portable bitmap and JPEG writer, used where makeImage.mm (Cocoa / ImageIO) is not available.

#include "Platform.hpp"

#if !SAPF_APPLE_IMAGE

#include "makeImage.hpp"
#include "Object.hpp"
#include <stdlib.h>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../third_party/stb_image_write.h"

struct Bitmap
{
	unsigned char* data;
	int width, height;
	int bytesPerRow;
};

Bitmap* createBitmap(int width, int height)
{
	Bitmap* bitmap = (Bitmap*)calloc(1, sizeof(Bitmap));
	bitmap->width = width;
	bitmap->height = height;
	bitmap->bytesPerRow = 4 * width;
	bitmap->data = (unsigned char*)calloc((size_t)bitmap->bytesPerRow * height, 1);
	return bitmap;
}

void writeBitmap(Bitmap* bitmap, const char *path)
{
	if (!stbi_write_jpg(path, bitmap->width, bitmap->height, 4, bitmap->data, 90)) {
		post("could not write image \"%s\"\n", path);
	}
}

void freeBitmap(Bitmap* bitmap)
{
	free(bitmap->data);
	free(bitmap);
}

void setPixel(Bitmap* bitmap, int x, int y, int r, int g, int b, int a)
{
	size_t index = bitmap->bytesPerRow * y + 4 * x;
	unsigned char* data = bitmap->data;

	data[index+0] = r;
	data[index+1] = g;
	data[index+2] = b;
	data[index+3] = a;
}

void fillRect(Bitmap* bitmap, int x, int y, int width, int height, int r, int g, int b, int a)
{
	unsigned char* data = bitmap->data;
	for (int j = y; j < y + height; ++j) {
		size_t index = bitmap->bytesPerRow * j + 4 * x;
		for (int i = x; i < x + width; ++i) {
			data[index+0] = r;
			data[index+1] = g;
			data[index+2] = b;
			data[index+3] = a;
			index += 4;
		}
	}
}

#endif // !SAPF_APPLE_IMAGE
