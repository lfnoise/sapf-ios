//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

#import "makeImage.hpp"
#import <TargetConditionals.h>

#if TARGET_OS_IPHONE

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

struct Bitmap
{
	CGContextRef context;
	unsigned char* data;
	int bytesPerRow;
};

Bitmap* createBitmap(int width, int height)
{
	Bitmap* bitmap = (Bitmap*)calloc(1, sizeof(Bitmap));
	CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	// JPEG output has no alpha anyway, so skip it rather than premultiplying.
	bitmap->context = CGBitmapContextCreate(nullptr, width, height, 8, 0, colorSpace,
								kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
	CGColorSpaceRelease(colorSpace);
	bitmap->data = (unsigned char*)CGBitmapContextGetData(bitmap->context);
	bitmap->bytesPerRow = (int)CGBitmapContextGetBytesPerRow(bitmap->context);
	return bitmap;
}

void writeBitmap(Bitmap* bitmap, const char *path)
{
	CGImageRef image = CGBitmapContextCreateImage(bitmap->context);
	NSURL* url = [NSURL fileURLWithPath: [NSString stringWithUTF8String: path]];
	CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, nullptr);
	if (dest) {
		CGImageDestinationAddImage(dest, image, nullptr);
		CGImageDestinationFinalize(dest);
		CFRelease(dest);
	}
	CGImageRelease(image);
}

void freeBitmap(Bitmap* bitmap)
{
	CGContextRelease(bitmap->context);
	free(bitmap);
}

#else

#import <Cocoa/Cocoa.h>

struct Bitmap
{
	NSBitmapImageRep* rep;
	unsigned char* data;
	int bytesPerRow;
};

Bitmap* createBitmap(int width, int height)
{
	Bitmap* bitmap = (Bitmap*)calloc(1, sizeof(Bitmap));
	bitmap->rep = 
			[[NSBitmapImageRep alloc] 
				initWithBitmapDataPlanes: nullptr
				pixelsWide: width
				pixelsHigh: height
				bitsPerSample: 8
				samplesPerPixel: 4
				hasAlpha: YES
				isPlanar: NO
				colorSpaceName: NSCalibratedRGBColorSpace
				bitmapFormat: NSAlphaNonpremultipliedBitmapFormat
				bytesPerRow: 0
				bitsPerPixel: 32
			];
	
	bitmap->data = [bitmap->rep bitmapData];
	bitmap->bytesPerRow = (int)[bitmap->rep bytesPerRow];
	return bitmap;
}

void writeBitmap(Bitmap* bitmap, const char *path)
{
	//NSData* data = [bitmap->rep TIFFRepresentation];
	//NSDictionary* properties = @{ NSImageCompressionFactor: @.9 };
	NSDictionary* properties = nullptr;
	NSData* data = [bitmap->rep representationUsingType: NSJPEGFileType properties: properties];
	NSString* nsstr = [NSString stringWithUTF8String: path];
	[data writeToFile: nsstr atomically: YES];
}

void freeBitmap(Bitmap* bitmap)
{
	//[bitmap->rep release];
	free(bitmap);
}

#endif

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
