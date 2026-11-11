//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __PortableAccel_h__
#define __PortableAccel_h__

// Portable implementations of the subset of Apple's vDSP and vForce (double precision) that sapf uses,
// with the same names, argument orders, strides, scaling and packing conventions, so that call sites
// compile unchanged on platforms without Accelerate.
//
// Everything is declared in namespace sapf_accel. Unless SAPF_ACCEL_NO_USING is defined, the names
// are brought into the global namespace. tests/accel_test.cpp defines it to compare against Accelerate.

#include <cmath>
#include <cstdlib>
#include <cstring>

namespace sapf_accel {

typedef long vDSP_Stride;
typedef unsigned long vDSP_Length;

struct DSPDoubleComplex { double real; double imag; };
struct DSPDoubleSplitComplex { double* realp; double* imagp; };

enum { kFFTRadix2 = 0 };
enum { kFFTDirection_Forward = 1, kFFTDirection_Inverse = -1 };
enum { FFT_FORWARD = kFFTDirection_Forward, FFT_INVERSE = kFFTDirection_Inverse };
typedef int FFTDirection;
typedef int FFTRadix;

/////////////////////////////////////////////////////////////////////////////////////////////////////
// vForce. n is passed by pointer. results go to the first argument.

#define SAPF_VV1(NAME, EXPR) \
	inline void NAME(double* y, const double* x, const int* n) { \
		int nn = *n; for (int i = 0; i < nn; ++i) { double a = x[i]; y[i] = (EXPR); } }

SAPF_VV1(vvsin, std::sin(a))
SAPF_VV1(vvcos, std::cos(a))
SAPF_VV1(vvtan, std::tan(a))
SAPF_VV1(vvasin, std::asin(a))
SAPF_VV1(vvacos, std::acos(a))
SAPF_VV1(vvatan, std::atan(a))
SAPF_VV1(vvsinh, std::sinh(a))
SAPF_VV1(vvcosh, std::cosh(a))
SAPF_VV1(vvtanh, std::tanh(a))
SAPF_VV1(vvasinh, std::asinh(a))
SAPF_VV1(vvacosh, std::acosh(a))
SAPF_VV1(vvatanh, std::atanh(a))
SAPF_VV1(vvexp, std::exp(a))
SAPF_VV1(vvexp2, std::exp2(a))
SAPF_VV1(vvexpm1, std::expm1(a))
SAPF_VV1(vvlog, std::log(a))
SAPF_VV1(vvlog2, std::log2(a))
SAPF_VV1(vvlog10, std::log10(a))
SAPF_VV1(vvlog1p, std::log1p(a))
SAPF_VV1(vvlogb, std::logb(a))
SAPF_VV1(vvsqrt, std::sqrt(a))
SAPF_VV1(vvrsqrt, 1. / std::sqrt(a))
SAPF_VV1(vvrec, 1. / a)
SAPF_VV1(vvfabs, std::fabs(a))
SAPF_VV1(vvfloor, std::floor(a))
SAPF_VV1(vvceil, std::ceil(a))
SAPF_VV1(vvnint, std::nearbyint(a))

#undef SAPF_VV1

// z = x ^ y  (note the argument order: exponent before base)
inline void vvpow(double* z, const double* y, const double* x, const int* n)
{ int nn = *n; for (int i = 0; i < nn; ++i) z[i] = std::pow(x[i], y[i]); }

// z = atan2(y, x)
inline void vvatan2(double* z, const double* y, const double* x, const int* n)
{ int nn = *n; for (int i = 0; i < nn; ++i) z[i] = std::atan2(y[i], x[i]); }

// z = copysign(y, x): magnitude of y, sign of x
inline void vvcopysign(double* z, const double* y, const double* x, const int* n)
{ int nn = *n; for (int i = 0; i < nn; ++i) z[i] = std::copysign(y[i], x[i]); }

// z = nextafter(y, x)
inline void vvnextafter(double* z, const double* y, const double* x, const int* n)
{ int nn = *n; for (int i = 0; i < nn; ++i) z[i] = std::nextafter(y[i], x[i]); }

/////////////////////////////////////////////////////////////////////////////////////////////////////
// vDSP vector ops. strides are in elements.

inline void vDSP_vsmulD(const double* A, vDSP_Stride IA, const double* B, double* C, vDSP_Stride IC, vDSP_Length N)
{ double b = *B; for (vDSP_Length i = 0; i < N; ++i) C[i*IC] = A[i*IA] * b; }

inline void vDSP_vsaddD(const double* A, vDSP_Stride IA, const double* B, double* C, vDSP_Stride IC, vDSP_Length N)
{ double b = *B; for (vDSP_Length i = 0; i < N; ++i) C[i*IC] = A[i*IA] + b; }

// C = B / A  (scalar divided by vector)
inline void vDSP_svdivD(const double* A, const double* B, vDSP_Stride IB, double* C, vDSP_Stride IC, vDSP_Length N)
{ double a = *A; for (vDSP_Length i = 0; i < N; ++i) C[i*IC] = a / B[i*IB]; }

inline void vDSP_vnegD(const double* A, vDSP_Stride IA, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) C[i*IC] = -A[i*IA]; }

inline void vDSP_vaddD(const double* A, vDSP_Stride IA, const double* B, vDSP_Stride IB, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) C[i*IC] = A[i*IA] + B[i*IB]; }

// C = A - B, where B is the FIRST argument.
inline void vDSP_vsubD(const double* B, vDSP_Stride IB, const double* A, vDSP_Stride IA, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) C[i*IC] = A[i*IA] - B[i*IB]; }

inline void vDSP_vmulD(const double* A, vDSP_Stride IA, const double* B, vDSP_Stride IB, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) C[i*IC] = A[i*IA] * B[i*IB]; }

// C = A / B, where B is the FIRST argument.
inline void vDSP_vdivD(const double* B, vDSP_Stride IB, const double* A, vDSP_Stride IA, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) C[i*IC] = A[i*IA] / B[i*IB]; }

inline void vDSP_vmaxD(const double* A, vDSP_Stride IA, const double* B, vDSP_Stride IB, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) { double a = A[i*IA], b = B[i*IB]; C[i*IC] = a > b ? a : b; } }

inline void vDSP_vminD(const double* A, vDSP_Stride IA, const double* B, vDSP_Stride IB, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) { double a = A[i*IA], b = B[i*IB]; C[i*IC] = a < b ? a : b; } }

// C = sqrt(A^2 + B^2)
inline void vDSP_vdistD(const double* A, vDSP_Stride IA, const double* B, vDSP_Stride IB, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) { double a = A[i*IA], b = B[i*IB]; C[i*IC] = std::sqrt(a*a + b*b); } }

inline void vDSP_vsqD(const double* A, vDSP_Stride IA, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) { double a = A[i*IA]; C[i*IC] = a * a; } }

// signed square: A * |A|
inline void vDSP_vssqD(const double* A, vDSP_Stride IA, double* C, vDSP_Stride IC, vDSP_Length N)
{ for (vDSP_Length i = 0; i < N; ++i) { double a = A[i*IA]; C[i*IC] = a * std::fabs(a); } }

// decibels. F == 1: amplitude, 20 log10(A/B). F == 0: power, 10 log10(A/B).
inline void vDSP_vdbconD(const double* A, vDSP_Stride IA, const double* B, double* C, vDSP_Stride IC, vDSP_Length N, unsigned int F)
{
	double b = *B;
	double k = F ? 20. : 10.;
	for (vDSP_Length i = 0; i < N; ++i) C[i*IC] = k * std::log10(A[i*IA] / b);
}

// polar (magnitude, phase) pairs to rectangular (real, imag) pairs. strides are in doubles and must be even.
inline void vDSP_rectD(const double* A, vDSP_Stride IA, double* C, vDSP_Stride IC, vDSP_Length N)
{
	for (vDSP_Length i = 0; i < N; ++i) {
		double r = A[i*IA], th = A[i*IA+1];
		C[i*IC] = r * std::cos(th);
		C[i*IC+1] = r * std::sin(th);
	}
}

// interleaved complex to split complex. IC is in doubles (2 == contiguous complex values).
inline void vDSP_ctozD(const DSPDoubleComplex* C, vDSP_Stride IC, const DSPDoubleSplitComplex* Z, vDSP_Stride IZ, vDSP_Length N)
{
	const double* c = (const double*)C;
	for (vDSP_Length i = 0; i < N; ++i) {
		Z->realp[i*IZ] = c[i*IC];
		Z->imagp[i*IZ] = c[i*IC+1];
	}
}

// split complex to interleaved complex. IC is in doubles.
inline void vDSP_ztocD(const DSPDoubleSplitComplex* Z, vDSP_Stride IZ, DSPDoubleComplex* C, vDSP_Stride IC, vDSP_Length N)
{
	double* c = (double*)C;
	for (vDSP_Length i = 0; i < N; ++i) {
		c[i*IC] = Z->realp[i*IZ];
		c[i*IC+1] = Z->imagp[i*IZ];
	}
}

// windows. Flag 0 gives the full window of length N with denominator N.
inline void vDSP_hann_windowD(double* C, vDSP_Length N, int Flag)
{
	(void)Flag;
	for (vDSP_Length i = 0; i < N; ++i) C[i] = .5 * (1. - std::cos(2. * M_PI * i / N));
}

inline void vDSP_hamm_windowD(double* C, vDSP_Length N, int Flag)
{
	(void)Flag;
	for (vDSP_Length i = 0; i < N; ++i) C[i] = .54 - .46 * std::cos(2. * M_PI * i / N);
}

inline void vDSP_blkman_windowD(double* C, vDSP_Length N, int Flag)
{
	(void)Flag;
	for (vDSP_Length i = 0; i < N; ++i) {
		double w = 2. * M_PI * i / N;
		C[i] = .42 - .5 * std::cos(w) + .08 * std::cos(2. * w);
	}
}

/////////////////////////////////////////////////////////////////////////////////////////////////////
// FFT. radix 2, unnormalized, vDSP conventions:
//   complex forward:  X[k] = sum x[n] e^(-2 pi i k n / N)        inverse uses e^(+...)
//   real forward of N points (input packed as N/2 complex: even samples in realp, odd in imagp):
//      output is 2 * X[k] for k = 0 .. N/2-1, with realp[0] = 2 X[0] and imagp[0] = 2 X[N/2].
//   real inverse takes that packed format and produces the N/2-point packed real sequence
//      x[n] = sum over the full Hermitian spectrum of Y[k] e^(+2 pi i k n / N).

struct OpaqueFFTSetupD
{
	int log2nMax;
	double* cosTable;   // cos(2 pi k / Nmax), k < Nmax/2
	double* sinTable;   // sin(2 pi k / Nmax)
};
typedef OpaqueFFTSetupD* FFTSetupD;

inline FFTSetupD vDSP_create_fftsetupD(vDSP_Length log2n, FFTRadix)
{
	FFTSetupD s = new OpaqueFFTSetupD;
	s->log2nMax = (int)log2n;
	size_t n = (size_t)1 << log2n;
	size_t half = n > 1 ? n / 2 : 1;
	s->cosTable = new double[half];
	s->sinTable = new double[half];
	for (size_t k = 0; k < half; ++k) {
		double w = 2. * M_PI * (double)k / (double)n;
		s->cosTable[k] = std::cos(w);
		s->sinTable[k] = std::sin(w);
	}
	return s;
}

inline void vDSP_destroy_fftsetupD(FFTSetupD s)
{
	if (!s) return;
	delete [] s->cosTable;
	delete [] s->sinTable;
	delete s;
}

namespace detail {

// in-place complex FFT of size 2^log2n on contiguous split arrays. dir: +1 forward, -1 inverse.
inline void fftInPlace(FFTSetupD s, double* re, double* im, int log2n, int dir)
{
	size_t n = (size_t)1 << log2n;
	if (n < 2) return;

	// bit reversal permutation
	for (size_t i = 1, j = 0; i < n; ++i) {
		size_t bit = n >> 1;
		for (; j & bit; bit >>= 1) j ^= bit;
		j ^= bit;
		if (i < j) {
			double t = re[i]; re[i] = re[j]; re[j] = t;
			t = im[i]; im[i] = im[j]; im[j] = t;
		}
	}

	int tableShift = s->log2nMax - log2n;
	for (size_t len = 2, lenLog = 1; len <= n; len <<= 1, ++lenLog) {
		size_t halfLen = len >> 1;
		size_t step = (size_t)1 << (log2n - lenLog + tableShift); // index stride into the Nmax tables
		for (size_t start = 0; start < n; start += len) {
			for (size_t k = 0; k < halfLen; ++k) {
				double wr = s->cosTable[k * step];
				double wi = -dir * s->sinTable[k * step];
				size_t a = start + k, b = a + halfLen;
				double xr = re[b] * wr - im[b] * wi;
				double xi = re[b] * wi + im[b] * wr;
				re[b] = re[a] - xr;
				im[b] = im[a] - xi;
				re[a] += xr;
				im[a] += xi;
			}
		}
	}
}

// twiddle e^(-dir 2 pi i k / 2^log2n) taken from the setup's tables.
inline void twiddle(FFTSetupD s, int log2n, size_t k, int dir, double& wr, double& wi)
{
	size_t idx = k << (s->log2nMax - log2n);
	wr = s->cosTable[idx];
	wi = -dir * s->sinTable[idx];
}

} // namespace detail

inline void vDSP_fft_zipD(FFTSetupD s, const DSPDoubleSplitComplex* io, vDSP_Stride stride, vDSP_Length log2n, FFTDirection dir)
{
	(void)stride; // sapf only uses stride 1
	detail::fftInPlace(s, io->realp, io->imagp, (int)log2n, dir);
}

inline void vDSP_fft_zopD(FFTSetupD s, const DSPDoubleSplitComplex* in, vDSP_Stride inStride,
                          const DSPDoubleSplitComplex* out, vDSP_Stride outStride, vDSP_Length log2n, FFTDirection dir)
{
	(void)inStride; (void)outStride;
	size_t n = (size_t)1 << log2n;
	if (out->realp != in->realp) memmove(out->realp, in->realp, n * sizeof(double));
	if (out->imagp != in->imagp) memmove(out->imagp, in->imagp, n * sizeof(double));
	detail::fftInPlace(s, out->realp, out->imagp, (int)log2n, dir);
}

// real FFT in place on N/2 packed points. log2n is log2 of the real length N.
inline void vDSP_fft_zripD(FFTSetupD s, const DSPDoubleSplitComplex* io, vDSP_Stride stride, vDSP_Length log2n, FFTDirection dir)
{
	(void)stride;
	int L = (int)log2n;
	if (L < 1) return;
	size_t m = (size_t)1 << (L - 1); // number of complex points
	double* re = io->realp;
	double* im = io->imagp;

	if (dir == kFFTDirection_Forward) {
		detail::fftInPlace(s, re, im, L - 1, +1);
		// unpack: 2X[k] = (Z[k] + conj Z[m-k]) - i W^k (Z[k] - conj Z[m-k]),  W = e^(-2 pi i / N)
		double z0r = re[0], z0i = im[0];
		re[0] = 2. * (z0r + z0i);   // 2 X[0]
		im[0] = 2. * (z0r - z0i);   // 2 X[N/2]
		for (size_t k = 1; k <= m / 2; ++k) {
			size_t j = m - k;
			double akr = re[k], aki = im[k];
			double ajr = re[j], aji = im[j];
			// for bin k
			double sr = akr + ajr, si = aki - aji;      // Z[k] + conj Z[j]
			double dr = akr - ajr, di = aki + aji;      // Z[k] - conj Z[j]
			double wr, wi; detail::twiddle(s, L, k, +1, wr, wi);
			// -i * W * d = -i * (wr + i wi)(dr + i di) = (wr di + wi dr) + i (wi di - wr dr)
			double tr = wr * di + wi * dr;
			double ti = wi * di - wr * dr;
			double xkr = sr + tr, xki = si + ti;
			// for bin j: Z[j] + conj Z[k] = conj(sr + i si)... computed directly
			double sjr = ajr + akr, sji = aji - aki;
			double djr = ajr - akr, dji = aji + aki;
			double vr, vi; detail::twiddle(s, L, j, +1, vr, vi);
			double ujr = vr * dji + vi * djr;
			double uji = vi * dji - vr * djr;
			re[k] = xkr; im[k] = xki;
			if (j != k) { re[j] = sjr + ujr; im[j] = sji + uji; }
		}
	} else {
		// pack: Z[k] = (A[k] + conj A[m-k]) + i W^-k (A[k] - conj A[m-k]),  with A[0] = realp[0], A[m] = imagp[0]
		double a0 = re[0], am = im[0];
		re[0] = a0 + am;
		im[0] = a0 - am;
		for (size_t k = 1; k <= m / 2; ++k) {
			size_t j = m - k;
			double akr = re[k], aki = im[k];
			double ajr = re[j], aji = im[j];
			double sr = akr + ajr, si = aki - aji;
			double dr = akr - ajr, di = aki + aji;
			double wr, wi; detail::twiddle(s, L, k, -1, wr, wi); // e^(+2 pi i k / N)
			// i * W * d = i (wr + i wi)(dr + i di) = -(wr di + wi dr) + i (wr dr - wi di)
			double tr = -(wr * di + wi * dr);
			double ti = wr * dr - wi * di;
			double sjr = ajr + akr, sji = aji - aki;
			double djr = ajr - akr, dji = aji + aki;
			double vr, vi; detail::twiddle(s, L, j, -1, vr, vi);
			double ujr = -(vr * dji + vi * djr);
			double uji = vr * djr - vi * dji;
			re[k] = sr + tr; im[k] = si + ti;
			if (j != k) { re[j] = sjr + ujr; im[j] = sji + uji; }
		}
		detail::fftInPlace(s, re, im, L - 1, -1);
	}
}

inline void vDSP_fft_zropD(FFTSetupD s, const DSPDoubleSplitComplex* in, vDSP_Stride inStride,
                           const DSPDoubleSplitComplex* out, vDSP_Stride outStride, vDSP_Length log2n, FFTDirection dir)
{
	(void)inStride;
	size_t m = log2n >= 1 ? (size_t)1 << (log2n - 1) : 1;
	if (out->realp != in->realp) memmove(out->realp, in->realp, m * sizeof(double));
	if (out->imagp != in->imagp) memmove(out->imagp, in->imagp, m * sizeof(double));
	vDSP_fft_zripD(s, out, outStride, log2n, dir);
}

} // namespace sapf_accel

#ifndef SAPF_ACCEL_NO_USING
using namespace sapf_accel;
#endif

#endif
