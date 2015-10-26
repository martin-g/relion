#include "src/gpu_utils/cuda_kernels/helper.cuh"

__global__ void cuda_kernel_exponentiate_weights(  XFLOAT *g_pdf_orientation,
									     	  XFLOAT *g_pdf_offset,
									     	  XFLOAT *g_Mweight,
									     	  XFLOAT min_diff2,
									     	  int nr_coarse_orient,
									     	  int nr_coarse_trans,
									     	  long int sumweight_pos)
{
	// blockid
	int bid  = blockIdx.x;
	//threadid
	int tid = threadIdx.x;

	int pos, iorient = bid*SUMW_BLOCK_SIZE+tid;

	XFLOAT weight;
	if(iorient<nr_coarse_orient)
	{
		for (int itrans=0; itrans<nr_coarse_trans; itrans++)
		{
			pos = iorient * nr_coarse_trans + itrans;
			XFLOAT diff2 = g_Mweight[pos] - min_diff2;
			if( diff2 < (XFLOAT)0.0 ) //TODO Might be slow (divergent threads)
				diff2 = (XFLOAT)0.0;
			else
			{
				weight = g_pdf_orientation[iorient] * g_pdf_offset[itrans];          	// Same for all threads - TODO: should be done once for all trans through warp-parallel execution

				// next line because of numerical precision of exp-function
#if defined(CUDA_DOUBLE_PRECISION)
				if (diff2 > 700.)
					weight = 0.;
				else
					weight *= exp(-diff2);
#else
				if (diff2 > 88.)
					weight = 0.;
				else
					weight *= expf(-diff2);
#endif
				diff2=weight;
				// TODO: use tabulated exp function? / Sjors  TODO: exp, expf, or __exp in CUDA? /Bjorn
			}

			// Store the weight
			g_Mweight[pos] = diff2; // TODO put in shared mem
		}
	}
}


/*
 * This draft of a kernel assumes input that has jobs which have a single orientation and sequential translations within each job.
 *
 */
__global__ void cuda_kernel_sumweightFine(    XFLOAT *g_pdf_orientation,
									     	  XFLOAT *g_pdf_offset,
									     	  XFLOAT *g_weights,
									     	  XFLOAT *g_thisparticle_sumweight,
									     	  XFLOAT min_diff2,
									     	  int oversamples_orient,
									     	  int oversamples_trans,
									     	  unsigned long *d_rot_id,
									     	  unsigned long *d_trans_idx,
									     	  unsigned long *d_job_idx,
									     	  unsigned long *d_job_num,
									     	  long int job_num,
									     	  long int sumweight_pos)
{
	__shared__ XFLOAT s_sumweight[SUMW_BLOCK_SIZE];
	__shared__ XFLOAT s_weights[SUMW_BLOCK_SIZE];

	// blockid
	int bid  = blockIdx.x;
	//threadid
	int tid = threadIdx.x;

	s_sumweight[tid]=0.;

	long int jobid = bid*SUMW_BLOCK_SIZE+tid;

	if (jobid<job_num)
	{
		long int pos = d_job_idx[jobid];
		// index of comparison
		long int ix =  d_rot_id[   pos];   // each thread gets its own orient...
		long int iy = d_trans_idx[ pos];   // ...and it's starting trans...
		long int in =  d_job_num[jobid];    // ...AND the number of translations to go through

		int c_itrans;//, iorient = bid*SUM_BLOCK_SIZE+tid; //, f_itrans;

		// Bacause the partion of work is so arbitrarily divided in this kernel,
		// we need to do some brute idex work to get the correct indices.
		for (int itrans=0; itrans < in; itrans++, iy++)
		{
			c_itrans = ( iy - (iy % oversamples_trans))/ oversamples_trans; //floor(x/y) == (x-(x%y))/y  but less sensitive to x>>y and finite precision
//			f_itrans = iy % oversamples_trans;

			XFLOAT prior = g_pdf_orientation[ix] * g_pdf_offset[c_itrans];          	// Same      for all threads - TODO: should be done once for all trans through warp-parallel execution
			XFLOAT diff2 = g_weights[pos+itrans] - min_diff2;								// Different for all threads
			// next line because of numerical precision of exp-function
	#if defined(CUDA_DOUBLE_PRECISION)
				if (diff2 > 700.)
					s_weights[tid] = 0.;
				else
					s_weights[tid] = prior * exp(-diff2);
	#else
				if (diff2 > 88.)
					s_weights[tid] = 0.;
				else
					s_weights[tid] = prior * expf(-diff2);
	#endif
				// TODO: use tabulated exp function? / Sjors  TODO: exp, expf, or __exp in CUDA? /Bjorn
			// Store the weight
			g_weights[pos+itrans] = s_weights[tid]; // TODO put in shared mem

			// Reduce weights for sum of all weights
			s_sumweight[tid] += s_weights[tid];
		}
	}
	else
	{
		s_sumweight[tid]=0.;
	}

	__syncthreads();
	// Further reduction of all samples in this block
	// ProTip: to test reduction order (at this level), change "tid+j" to "2*j-tid-1",
	// since this will switch from a sliding-block-lik reduction to a fan-like reduction
	for(int j=(SUMW_BLOCK_SIZE/2); j>0; j/=2)
	{
		if(tid<j)
			s_sumweight[tid] += s_sumweight[tid+j];
	}
	__syncthreads();
	g_thisparticle_sumweight[bid+sumweight_pos]=s_sumweight[0];
}

__global__ void cuda_kernel_collect2jobs(	XFLOAT *g_oo_otrans_x,          // otrans-size -> make const
										XFLOAT *g_oo_otrans_y,          // otrans-size -> make const
										XFLOAT *g_myp_oo_otrans_x2y2z2, // otrans-size -> make const
										XFLOAT *g_i_weights,
										XFLOAT op_significant_weight,    // TODO Put in const
										XFLOAT op_sum_weight,            // TODO Put in const
										int   coarse_trans,
										int   oversamples_trans,
										int   oversamples_orient,
										int   oversamples,
										bool  do_ignore_pdf_direction,
										XFLOAT *g_o_weights,
										XFLOAT *g_thr_wsum_prior_offsetx_class,
										XFLOAT *g_thr_wsum_prior_offsety_class,
										XFLOAT *g_thr_wsum_sigma2_offset,
								     	unsigned long *d_rot_idx,
								     	unsigned long *d_trans_idx,
								     	unsigned long *d_job_idx,
								     	unsigned long *d_job_num
								     	)
{
	// blockid
	int bid  =blockIdx.x * gridDim.y + blockIdx.y;
	//threadid
	int tid = threadIdx.x;

	__shared__ XFLOAT                    s_o_weights[SUMW_BLOCK_SIZE];
	__shared__ XFLOAT s_thr_wsum_prior_offsetx_class[SUMW_BLOCK_SIZE];
	__shared__ XFLOAT s_thr_wsum_prior_offsety_class[SUMW_BLOCK_SIZE];
	__shared__ XFLOAT       s_thr_wsum_sigma2_offset[SUMW_BLOCK_SIZE];
	s_o_weights[tid]                    = (XFLOAT)0.0;
	s_thr_wsum_prior_offsetx_class[tid] = (XFLOAT)0.0;
	s_thr_wsum_prior_offsety_class[tid] = (XFLOAT)0.0;
	s_thr_wsum_sigma2_offset[tid]       = (XFLOAT)0.0;

	long int pos = d_job_idx[bid];
    int job_size = d_job_num[bid];
	pos += tid;	   					// pos is updated to be thread-resolved

    int pass_num = ceil((float)job_size / (float)SUMW_BLOCK_SIZE);
    for (int pass = 0; pass < pass_num; pass++, pos+=SUMW_BLOCK_SIZE) // loop the available warps enough to complete all translations for this orientation
    {
    	if ((pass*SUMW_BLOCK_SIZE+tid)<job_size) // if there is a translation that needs to be done still for this thread
    	{
			// index of comparison
			long int iy = d_trans_idx[pos];              // ...and its own trans...

			XFLOAT weight = g_i_weights[pos];
			if( weight >= op_significant_weight ) //TODO Might be slow (divergent threads)
				weight /= op_sum_weight;
			else
				weight = 0.0f;

			s_o_weights[tid] += weight;
			s_thr_wsum_prior_offsetx_class[tid] += weight *          g_oo_otrans_x[iy];
			s_thr_wsum_prior_offsety_class[tid] += weight *          g_oo_otrans_y[iy];
			s_thr_wsum_sigma2_offset[tid]       += weight * g_myp_oo_otrans_x2y2z2[iy];
    	}
    }
    // Reduction of all treanslations this orientation
	for(int j=(SUMW_BLOCK_SIZE/2); j>0; j/=2)
	{
		if(tid<j)
		{
			s_o_weights[tid]                    += s_o_weights[tid+j];
			s_thr_wsum_prior_offsetx_class[tid] += s_thr_wsum_prior_offsetx_class[tid+j];
			s_thr_wsum_prior_offsety_class[tid] += s_thr_wsum_prior_offsety_class[tid+j];
			s_thr_wsum_sigma2_offset[tid]       += s_thr_wsum_sigma2_offset[tid+j];
		}
		__syncthreads();
	}
	g_o_weights[bid]			           = s_o_weights[0];
	g_thr_wsum_prior_offsetx_class[bid] = s_thr_wsum_prior_offsetx_class[0];
	g_thr_wsum_prior_offsety_class[bid] = s_thr_wsum_prior_offsety_class[0];
	g_thr_wsum_sigma2_offset[bid]       = s_thr_wsum_sigma2_offset[0];
}
__global__ void cuda_kernel_softMaskOutsideMap(	XFLOAT *vol,
												long int vol_size,
												long int xdim,
												long int ydim,
												long int zdim,
												long int xinit,
												long int yinit,
												long int zinit,
												bool do_Mnoise,
												XFLOAT radius,
												XFLOAT radius_p,
												XFLOAT cosine_width	)
{

		int tid = threadIdx.x;

//		vol.setXmippOrigin(); // sets xinit=xdim , also for y z
		XFLOAT r, raisedcos;

		__shared__ XFLOAT     img_pixels[SOFTMASK_BLOCK_SIZE];
		__shared__ XFLOAT    partial_sum[SOFTMASK_BLOCK_SIZE];
		__shared__ XFLOAT partial_sum_bg[SOFTMASK_BLOCK_SIZE];

		XFLOAT sum_bg_total = 0.f;

		long int texel_pass_num = ceilf((float)vol_size/(float)SOFTMASK_BLOCK_SIZE);
		int texel = tid;

		partial_sum[tid]=0.f;
		partial_sum_bg[tid]=0.f;
		if (do_Mnoise)
		{
			for (int pass = 0; pass < texel_pass_num; pass++, texel+=SOFTMASK_BLOCK_SIZE) // loop the available warps enough to complete all translations for this orientation
			{
				XFLOAT x,y,z;
				if(texel<vol_size)
				{
					img_pixels[tid]=__ldg(&vol[texel]);

					z = 0.f;// floor( (float) texel                  / (float)((xdim)*(ydim)));
					y = floor( (float)(texel-z*(xdim)*(ydim)) / (float)  xdim         );
					x = texel - z*(xdim)*(ydim) - y*xdim;

	//				z-=zinit;
					y-=yinit;
					x-=xinit;

					r = sqrt(x*x + y*y);// + z*z);

					if (r < radius)
						continue;
					else if (r > radius_p)
					{
						partial_sum[tid]    += 1.f;
						partial_sum_bg[tid] += img_pixels[tid];
					}
					else
					{
						raisedcos = 0.5f + 0.5f * cospif((radius_p - r) / cosine_width );
						partial_sum[tid] += raisedcos;
						partial_sum_bg[tid] += raisedcos * img_pixels[tid];
					}
				}
			}
		}

		__syncthreads();
		for(int j=(SOFTMASK_BLOCK_SIZE/2); j>0; j/=2)
		{
			if(tid<j)
			{
				partial_sum[tid] += partial_sum[tid+j];
				partial_sum_bg[tid] += partial_sum_bg[tid+j];
			}
			__syncthreads();
		}

		sum_bg_total  = partial_sum_bg[0] / partial_sum[0];


		texel = tid;
		for (int pass = 0; pass < texel_pass_num; pass++, texel+=SOFTMASK_BLOCK_SIZE) // loop the available warps enough to complete all translations for this orientation
		{
			XFLOAT x,y,z;
			if(texel<vol_size)
			{
				img_pixels[tid]=__ldg(&vol[texel]);

				z = 0.f;// floor( (float) texel                  / (float)((xdim)*(ydim)));
				y = floor( (float)(texel-z*(xdim)*(ydim)) / (float)  xdim         );
				x = texel - z*(xdim)*(ydim) - y*xdim;

//				z-=zinit;
				y-=yinit;
				x-=xinit;

				r = sqrt(x*x + y*y);// + z*z);

				if (r < radius)
					continue;
				else if (r > radius_p)
					img_pixels[tid]=sum_bg_total;
				else
				{
					raisedcos = 0.5f + 0.5f * cospif((radius_p - r) / cosine_width );
					img_pixels[tid]= img_pixels[tid]*(1-raisedcos) + sum_bg_total*raisedcos;
				}
				vol[texel]=img_pixels[tid];
			}

		}
}
