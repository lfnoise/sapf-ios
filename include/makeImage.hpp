//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

typedef struct Bitmap Bitmap;

Bitmap* createBitmap(int width, int height);
void freeBitmap(Bitmap* bitmap);

void setPixel(Bitmap* bitmap, int x, int y, int r, int g, int b, int a);
void fillRect(Bitmap* bitmap, int x, int y, int width, int height, int r, int g, int b, int a);
void writeBitmap(Bitmap* bitmap, const char *path);



