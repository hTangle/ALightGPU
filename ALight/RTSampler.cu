#include "RTSampler.h"
#include "Ray.h"
#include "Camera.h"
#include "float3Extension.h"
#include <curand_discrete2.h>
#include <device_launch_parameters.h>
#include <curand_kernel.h>
#include "Objects.h"
#include "float3x3.h"
#include "RTDeviceData.h"
#include "SurfaceHitRecord.h"
#include "BVH.h"
#include <cstdio>


__device__ Ray CreateCameraRay(Camera* camera, float u, float v)
{
	return Ray(camera->Origin, UnitVector(camera->LowerLeftCorner + u * camera->Horizontal + v * camera->Vertical - camera->Origin));
}
__device__ SurfaceHitRecord CreateRayHit()
{
	SurfaceHitRecord hit;
	hit.p = make_float3(0.0f, 0.0f, 0.0f);
	hit.t =INF;
	hit.normal = make_float3(0.0f, 0.0f, 0.0f);
	return hit;
}
__device__ bool IntersectTriangle_MT97(Ray ray, float3 vert0, float3 vert1, float3 vert2,float& t, float& u, float& v)
{
	// find vectors for two edges sharing vert0
	float3 edge1 = vert1 - vert0;
	float3 edge2 = vert2 - vert0;
	// begin calculating determinant - also used to calculate U parameter
	float3 pvec = Cross(ray.direction, edge2);
	// if determinant is near zero, ray lies in plane of triangle
	float det = Dot(edge1, pvec);
	// use backface culling
	if (det < EPSILON)return false;
	float inv_det = 1.0f / det;
	// calculate distance from vert0 to ray origin
	float3 tvec = ray.origin - vert0;
	// calculate U parameter and test bounds
	u = Dot(tvec, pvec) * inv_det;
	if (u < 0.0 || u > 1.0f)
		return false;
	// prepare to test V parameter
	float3 qvec = Cross(tvec, edge1);
	// calculate V parameter and test bounds
	v = Dot(ray.direction, qvec) * inv_det;
	if (v < 0.0 || u + v > 1.0f)
		return false;
	// calculate t, ray intersects triangle
	t = Dot(edge2, qvec) * inv_det;
	return true;
}
__device__ void IntersectTriangle(Ray ray,  SurfaceHitRecord* bestHit, RTDeviceData& data,  int material,
                                  float3 vert0, float3 vert1, float3 vert2)
{
	float t, u, v;
	if (IntersectTriangle_MT97(ray, vert0, vert1, vert2, t, u, v))
	{
		if (t > 0.00001 && t < bestHit->t)
		{
			bestHit->t = t;
			bestHit->p = ray.origin + t * ray.direction;
			bestHit->normal = UnitVector(Cross(vert1 - vert0, vert2 - vert0));
			bestHit->mat_ptr= &data.Materials[material];
		}
	}
}

__device__ void IntersectGroundPlane(Ray ray, SurfaceHitRecord* bestHit,RTDeviceData& data)
{
	const auto t = -ray.origin.y / ray.direction.y;
	if (t > 0.001 && t < bestHit->t)
	{
		bestHit->t = t;
		bestHit->p = ray.origin + t * ray.direction;
		bestHit->normal = make_float3(0.0f, 1.0f, 0.0f);
		bestHit->mat_ptr = &data.Materials[0];
	}
}
__device__ void IntersectSphere(Ray ray, SurfaceHitRecord* best_hit, const Sphere sphere,RTDeviceData& data,int material)
{
	const auto d = ray.origin - sphere.position;
	const auto p1 = Dot(ray.direction, d) * -1;
	const auto p2_sqr = p1 * p1 - Dot(d, d) + sphere.radius * sphere.radius;
	if (p2_sqr < 0)return;
	const auto p2 = sqrt(p2_sqr);
	const auto t = p1 - p2 > 0 ? p1 - p2 : p1 + p2;
	if (t > 0.001 && t < best_hit->t)
	{
		best_hit->t = t;
		best_hit->p = ray.origin + t * ray.direction;
		best_hit->normal = UnitVector(best_hit->p - sphere.position);
		best_hit->mat_ptr = &data.Materials[material];
	}
}
__device__ float3x3 GetTangentSpace(float3 normal)
{
	const auto helper =  (fabs(normal.x) > 0.99f)? make_float3(0, 0, 1):make_float3(1, 0, 0);
	const auto tangent = UnitVector(Cross(normal, helper));
	const auto binormal = UnitVector(Cross(normal, tangent));
	return float3x3(tangent, binormal, normal);
}
__device__ bool HitAABB(const Ray& r, AABB* aabb, float tmin = 0, float tmax = FLT_MAX)
{
	for (auto a = 0; a < 3; a++)
	{
		const auto t0 = fmin((Get(aabb->min, a) - Get(r.origin, a)) / Get(r.direction, a),
		                     (Get(aabb->max, a) - Get(r.origin, a)) / Get(r.direction, a));
		const auto t1 = fmax((Get(aabb->min, a) - Get(r.origin, a)) / Get(r.direction, a),
		                     (Get(aabb->max, a) - Get(r.origin, a)) / Get(r.direction, a));
		tmin = fmax(t0, tmin);
		tmax = fmin(t1, tmax);
		if (tmax <= tmin)return false;
	}
	return true;
}

__device__ SurfaceHitRecord Trace(Ray ray,RTDeviceData& data)
{
	auto best_hit = CreateRayHit();
	BVH* stack[20];
	int ptr = 0;
	auto current = data.bvh;
	do
	{
		auto left = current->left;
		auto right = current->right;
		if (current->tri)
		{
			IntersectTriangle(ray, &best_hit, data, current->triangle->mat,
				current->triangle->v2.point,
				current->triangle->v1.point,
				current->triangle->v3.point);
			if (ptr <= 0)current = nullptr;
			else  current = stack[--ptr];
		}
		else
		{
			if (HitAABB(ray, current->aabb))
			{
				current= left;
				stack[ptr++]= right;
			}
			else
			{
				if (ptr <= 0)current = nullptr;
				else  current = stack[--ptr];
				
			}
		}
	} while (current!=nullptr);

	free(stack);
	IntersectGroundPlane(ray, &best_hit,data);



	// IntersectSphere(ray, &best_hit, Sphere(make_float3(0, 1, 0),1,make_float3(1,0,0),make_float3(0, 0, 0),1,make_float3(0,0,0)),data,1);
	// IntersectSphere(ray, &best_hit,Sphere(make_float3(2, 1, 0), 1, make_float3(1, 0, 0), make_float3(0, 0, 0),1, make_float3(0, 0, 0)), data,2);
	// IntersectSphere(ray, &best_hit,Sphere(make_float3(-2, 1, 0), 1, make_float3(1, 0, 0), make_float3(0, 0, 0),1, make_float3(0, 0, 0)), data, 3);
	return best_hit;
}

__device__ float3 Shade(Ray& ray, SurfaceHitRecord& hit, float3& factor, int depth, const RTDeviceData data)
{
	auto c = make_float3(0, 0, 0);
	if (hit.t < 99999)
	{
		float3 random_in_unit_sphere;
		do random_in_unit_sphere = 2.0 * make_float3(data.GetRandom(), data.GetRandom(), data.GetRandom()) - make_float3(1, 1, 1);
		while (SquaredLength(random_in_unit_sphere) >= 1.0);
		auto scattered = Ray();
		float3 attenuation;

		if (depth < 8 &&hit.mat_ptr->scatter(ray, hit, attenuation, scattered, random_in_unit_sphere, data))
		{
			factor *= attenuation;
			ray = scattered;
		}
		else return make_float3(-1,0,0);//break;
	}
	else return factor * data.SampleTexture(0, atan2(ray.direction.x, -ray.direction.z) / -M_PI * 0.5f, acos(ray.direction.y) / -M_PI);
	
	return c;
}


__global__ void IPRSampler(const int width, const int height, const int seed, const int spp,int Sampled, int mst, int root, float* output, curandState* const rngStates, Camera* camera,RTHostData host_data)
{
	const auto tidx = blockIdx.x * blockDim.x + threadIdx.x;
	const auto tidy = blockIdx.y * blockDim.y + threadIdx.y;
	const int x = blockIdx.x * 16 + threadIdx.x,
	          y = blockIdx.y * 16 + threadIdx.y;



	curand_init((seed + tidx + width * tidy)*Sampled, 0, 0, &rngStates[tidx]);
	auto data = RTDeviceData(rngStates, tidx, Sampled,make_float2(x,y));
	data.Materials = host_data.Materials;
	data.Textures = host_data.Textures;
	data.bvh = host_data.bvh;

	auto color = make_float3(0, 0, 0);
	auto result = make_float3(0, 0, 0);

	
	//Main Sampling
	for (auto j = 0; j < spp; j++)
	{
		const auto u = float(data.GetRandom() + x) / float(width);
		const auto v = float(data.GetRandom() + y) / float(height);
		auto ray = CreateCameraRay(camera, u, v);
		auto factor = make_float3(1, 1, 1);
		for (auto i = 0; i < mst; i++)
		{
			auto hit = Trace(ray,data);
			result =Shade(ray, hit, factor, i,data);
			if (result.x == -1) { result.x = 0; break; }
		}
		color += result;
	}


	//Set color to buffer.
	const auto i = width * 4 * y + x * 4;
	if(Sampled==spp)
	{
		output[i] = color.x;
		output[1 + i]= color.y;
		output[2 + i] = color.z;
		output[3 + i] = spp;
	}
	else
	{
		output[i] += color.x;
		output[1 + i] += color.y;
		output[2 + i] += color.z;
		output[3 + i] += spp;
	}

}