/* Copyright (c) 2016 PaddlePaddle Authors. All Rights Reserve.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include <thrust/execution_policy.h>
#include <thrust/reduce.h>
#include "paddle/operators/accuracy_op.h"
#include "paddle/platform/cuda_helper.h"
#include "paddle/platform/gpu_info.h"

namespace paddle {
namespace operators {
using platform::PADDLE_CUDA_NUM_THREADS;

template <int BlockSize>
__global__ void AccuracyCudaKernel(const int N, const int D,
                                   const int64_t* Xdata,
                                   const int64_t* labeldata, int* correct_data,
                                   float* accuracy) {
  int count = 0;
  __shared__ int total[BlockSize];

  // support only 1 block
  for (int i = threadIdx.x; i < (N); i += BlockSize) {
    for (int j = 0; j < D; ++j) {
      if (Xdata[i * D + j] == labeldata[i]) {
        ++count;
        break;
      }
    }
  }
  total[threadIdx.x] = count;
  __syncthreads();

  // reduce the count with init value 0, and output accuracy.
  int result = thrust::reduce(thrust::device, total, total + BlockSize, 0);
  if (threadIdx.x == 0) {
    *correct_data = result;
    *accuracy = static_cast<float>(result) / static_cast<float>(N);
  }
}

template <typename T>
class AccuracyOpCUDAKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext& ctx) const override {
    PADDLE_ENFORCE(platform::is_gpu_place(ctx.GetPlace()),
                   "It must use GPUPlace.");
    auto* inference = ctx.Input<Tensor>("Out");
    auto* indices = ctx.Input<Tensor>("Indices");
    auto* label = ctx.Input<Tensor>("Label");

    auto* accuracy = ctx.Output<Tensor>("Accuracy");
    auto* correct = ctx.Output<Tensor>("Correct");
    auto* total = ctx.Output<Tensor>("Total");
    // FIXME(typhoonzero): only support indices currently
    // if add support for output values, how to detect the data type?
    const int64_t* indices_data = indices->data<int64_t>();
    const int64_t* label_data = label->data<int64_t>();

    int* correct_data = correct->mutable_data<int>(ctx.GetPlace());
    int* total_data = total->mutable_data<int>(ctx.GetPlace());
    float* accuracy_data = accuracy->mutable_data<float>(ctx.GetPlace());

    int num_samples = static_cast<int>(inference->dims()[0]);
    size_t infer_width = inference->dims()[1];
    auto stream = ctx.cuda_device_context().stream();
    platform::GpuMemsetAsync(accuracy_data, 0, sizeof(float), stream);

    if (num_samples == 0) {
      return;
    }
    platform::GpuMemcpyAsync(total_data, &num_samples, sizeof(int),
                             cudaMemcpyHostToDevice, stream);

    AccuracyCudaKernel<
        PADDLE_CUDA_NUM_THREADS><<<1, PADDLE_CUDA_NUM_THREADS, 0, stream>>>(
        num_samples, infer_width, indices_data, label_data, correct_data,
        accuracy_data);

    int d_num_samples, d_num_correct;
    float d_accuracy;
    platform::GpuMemcpyAsync(&d_num_correct, correct_data, sizeof(int),
                             cudaMemcpyDeviceToHost, stream);
    platform::GpuMemcpyAsync(&d_num_samples, total_data, sizeof(int),
                             cudaMemcpyDeviceToHost, stream);
    platform::GpuMemcpyAsync(&d_accuracy, accuracy_data, sizeof(float),
                             cudaMemcpyDeviceToHost, stream);
  }
};

}  // namespace operators
}  // namespace paddle

// FIXME(typhoonzero): types of T is for inference data.
// label data is always int64
REGISTER_OP_GPU_KERNEL(accuracy, paddle::operators::AccuracyOpCUDAKernel<float>,
                       paddle::operators::AccuracyOpCUDAKernel<double>);
