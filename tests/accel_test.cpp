//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Compares PortableAccel.hpp against Apple's Accelerate on macOS.
// Build and run:  make accel-test

#include <Accelerate/Accelerate.h>
#define SAPF_ACCEL_NO_USING
#include "PortableAccel.hpp"
#include <cstdio>
#include <vector>
#include <random>

namespace P = sapf_accel;

static int gFailures = 0;

static void check(const char* name, const double* a, const double* b, size_t n, double tol)
{
	double worst = 0.; size_t at = 0;
	for (size_t i = 0; i < n; ++i) {
		double d = std::fabs(a[i] - b[i]);
		double scale = std::fmax(1., std::fabs(a[i]));
		if (std::isnan(a[i]) != std::isnan(b[i])) d = INFINITY;
		else if (std::isnan(a[i])) d = 0.;
		else if (std::isinf(a[i]) || std::isinf(b[i])) d = (a[i] == b[i]) ? 0. : INFINITY;
		d /= scale;
		if (d > worst) { worst = d; at = i; }
	}
	bool ok = worst <= tol;
	if (!ok) ++gFailures;
	printf("%-6s %-22s max rel err %.3g%s\n", ok ? "ok" : "FAIL", name, worst,
	       ok ? "" : "");
	if (!ok) printf("        at %zu: accelerate %.17g portable %.17g\n", at, a[at], b[at]);
}

int main()
{
	std::mt19937_64 rng(1234);
	std::uniform_real_distribution<double> uni(-4., 4.);
	std::uniform_real_distribution<double> pos(0.01, 4.);
	std::uniform_real_distribution<double> unit(-0.99, 0.99);

	const int n = 1000;
	std::vector<double> x(n), y(n), p(n), u(n), r1(n), r2(n);
	for (int i = 0; i < n; ++i) { x[i] = uni(rng); y[i] = uni(rng); p[i] = pos(rng); u[i] = unit(rng); }
	x[0] = 2.5; x[1] = -2.5; x[2] = 0.5; x[3] = 3.5; // rounding ties for nint

	const double tol = 1e-13;

#define VV1(NAME, IN) NAME(r1.data(), IN.data(), &n); P::NAME(r2.data(), IN.data(), &n); check(#NAME, r1.data(), r2.data(), n, tol);
	VV1(vvsin, x) VV1(vvcos, x) VV1(vvtan, x) VV1(vvasin, u) VV1(vvacos, u) VV1(vvatan, x)
	VV1(vvsinh, x) VV1(vvcosh, x) VV1(vvtanh, x) VV1(vvasinh, x) VV1(vvacosh, p) VV1(vvatanh, u)
	VV1(vvexp, x) VV1(vvexp2, x) VV1(vvexpm1, x) VV1(vvlog, p) VV1(vvlog2, p) VV1(vvlog10, p)
	VV1(vvlog1p, p) VV1(vvlogb, p) VV1(vvsqrt, p) VV1(vvrsqrt, p) VV1(vvrec, x) VV1(vvfabs, x)
	VV1(vvfloor, x) VV1(vvceil, x) VV1(vvnint, x)
#define VV2(NAME, A, B) NAME(r1.data(), A.data(), B.data(), &n); P::NAME(r2.data(), A.data(), B.data(), &n); check(#NAME, r1.data(), r2.data(), n, tol);
	VV2(vvpow, x, p) VV2(vvatan2, x, y) VV2(vvcopysign, x, y) VV2(vvnextafter, x, y)

	double b = 1.7;
	vDSP_vsmulD(x.data(), 1, &b, r1.data(), 1, n); P::vDSP_vsmulD(x.data(), 1, &b, r2.data(), 1, n); check("vsmulD", r1.data(), r2.data(), n, 0);
	vDSP_vsaddD(x.data(), 1, &b, r1.data(), 1, n); P::vDSP_vsaddD(x.data(), 1, &b, r2.data(), 1, n); check("vsaddD", r1.data(), r2.data(), n, 0);
	vDSP_svdivD(&b, x.data(), 1, r1.data(), 1, n); P::vDSP_svdivD(&b, x.data(), 1, r2.data(), 1, n); check("svdivD", r1.data(), r2.data(), n, tol);
	vDSP_vnegD(x.data(), 1, r1.data(), 1, n); P::vDSP_vnegD(x.data(), 1, r2.data(), 1, n); check("vnegD", r1.data(), r2.data(), n, 0);
#define VD2(NAME) vDSP_##NAME(x.data(), 1, y.data(), 1, r1.data(), 1, n); P::vDSP_##NAME(x.data(), 1, y.data(), 1, r2.data(), 1, n); check(#NAME, r1.data(), r2.data(), n, tol);
	VD2(vaddD) VD2(vsubD) VD2(vmulD) VD2(vdivD) VD2(vmaxD) VD2(vminD) VD2(vdistD)
	vDSP_vsqD(x.data(), 1, r1.data(), 1, n); P::vDSP_vsqD(x.data(), 1, r2.data(), 1, n); check("vsqD", r1.data(), r2.data(), n, 0);
	vDSP_vssqD(x.data(), 1, r1.data(), 1, n); P::vDSP_vssqD(x.data(), 1, r2.data(), 1, n); check("vssqD", r1.data(), r2.data(), n, 0);
	double one = 1.;
	vDSP_vdbconD(p.data(), 1, &one, r1.data(), 1, n, 1); P::vDSP_vdbconD(p.data(), 1, &one, r2.data(), 1, n, 1); check("vdbconD amp", r1.data(), r2.data(), n, 1e-12);
	vDSP_rectD(p.data(), 2, r1.data(), 2, n/2); P::vDSP_rectD(p.data(), 2, r2.data(), 2, n/2); check("rectD", r1.data(), r2.data(), n, tol);

	vDSP_hann_windowD(r1.data(), 512, 0); P::vDSP_hann_windowD(r2.data(), 512, 0); check("hann_windowD", r1.data(), r2.data(), 512, 1e-12);
	vDSP_hamm_windowD(r1.data(), 512, 0); P::vDSP_hamm_windowD(r2.data(), 512, 0); check("hamm_windowD", r1.data(), r2.data(), 512, 1e-12);
	vDSP_blkman_windowD(r1.data(), 512, 0); P::vDSP_blkman_windowD(r2.data(), 512, 0); check("blkman_windowD", r1.data(), r2.data(), 512, 1e-12);

	// FFTs: several sizes, setup larger than the transform as sapf does.
	FFTSetupD as = vDSP_create_fftsetupD(16, kFFTRadix2);
	P::FFTSetupD ps = P::vDSP_create_fftsetupD(16, P::kFFTRadix2);
	for (int log2n : {1, 2, 3, 5, 8, 11, 13}) {
		size_t N = (size_t)1 << log2n;
		std::vector<double> ar(N), ai(N), br(N), bi(N), inr(N), ini(N);
		for (size_t i = 0; i < N; ++i) { inr[i] = uni(rng); ini[i] = uni(rng); }
		char label[64];
		double ftol = 1e-12 * log2n * 8;

		for (int dir : {1, -1}) {
			DSPDoubleSplitComplex ain = { inr.data(), ini.data() }, aout = { ar.data(), ai.data() };
			P::DSPDoubleSplitComplex pin = { inr.data(), ini.data() }, pout = { br.data(), bi.data() };
			vDSP_fft_zopD(as, &ain, 1, &aout, 1, log2n, dir);
			P::vDSP_fft_zopD(ps, &pin, 1, &pout, 1, log2n, dir);
			snprintf(label, 64, "fft_zop %s N=%zu", dir > 0 ? "fwd" : "inv", N);
			check(label, ar.data(), br.data(), N, ftol); check(label, ai.data(), bi.data(), N, ftol);
		}

		// real forward: N real samples packed as N/2 complex
		size_t M = N / 2;
		{
			std::vector<double> a1(M), a2(M), b1(M), b2(M);
			DSPDoubleSplitComplex az = { a1.data(), a2.data() };
			P::DSPDoubleSplitComplex pz = { b1.data(), b2.data() };
			vDSP_ctozD((DSPDoubleComplex*)inr.data(), 2, &az, 1, M);
			P::vDSP_ctozD((P::DSPDoubleComplex*)inr.data(), 2, &pz, 1, M);
			vDSP_fft_zripD(as, &az, 1, log2n, kFFTDirection_Forward);
			P::vDSP_fft_zripD(ps, &pz, 1, log2n, P::kFFTDirection_Forward);
			snprintf(label, 64, "fft_zrip fwd N=%zu", N);
			check(label, a1.data(), b1.data(), M, ftol); check(label, a2.data(), b2.data(), M, ftol);

			// inverse of the forward result
			vDSP_fft_zripD(as, &az, 1, log2n, kFFTDirection_Inverse);
			P::vDSP_fft_zripD(ps, &pz, 1, log2n, P::kFFTDirection_Inverse);
			snprintf(label, 64, "fft_zrip inv N=%zu", N);
			check(label, a1.data(), b1.data(), M, ftol); check(label, a2.data(), b2.data(), M, ftol);

			// zrop
			std::vector<double> c1(M), c2(M), d1(M), d2(M);
			vDSP_ctozD((DSPDoubleComplex*)inr.data(), 2, &az, 1, M);
			P::vDSP_ctozD((P::DSPDoubleComplex*)inr.data(), 2, &pz, 1, M);
			DSPDoubleSplitComplex ao = { c1.data(), c2.data() };
			P::DSPDoubleSplitComplex po = { d1.data(), d2.data() };
			vDSP_fft_zropD(as, &az, 1, &ao, 1, log2n, kFFTDirection_Forward);
			P::vDSP_fft_zropD(ps, &pz, 1, &po, 1, log2n, P::kFFTDirection_Forward);
			snprintf(label, 64, "fft_zrop fwd N=%zu", N);
			check(label, c1.data(), d1.data(), M, ftol); check(label, c2.data(), d2.data(), M, ftol);
		}
	}
	vDSP_destroy_fftsetupD(as);
	P::vDSP_destroy_fftsetupD(ps);

	printf("\n%s: %d failure(s)\n", gFailures ? "FAILED" : "PASSED", gFailures);
	return gFailures ? 1 : 0;
}
