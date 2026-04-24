# llama.cpp-linux-cluster-amd-apu
Container images and build files for cluster enabled AMD and Vulkan llama.cpp

This images have RPC+RDMA enabled binaries to enable llama.cpp clustering.

## For ROCm+RPC enabled llama.cpp and tools
ghcr.io/rjmalagon/llama.cpp-linux-cluster-amd-apu:rocm-latest

## For Vulkan+RPC enabled llama.cpp and tools (for older AMD APUs unsupported by ROCm)
ghcr.io/rjmalagon/llama.cpp-linux-cluster-amd-apu:vulkan-latest

## Llama.cpp RPC clustering 
To run an RPC-server yo can invoke the image passing "--rpc" parameter. It binds to 127.0.0.1:50052 and can change it with "-H HOST" and -"p PORT" parameters.
Example:

```
podman run --device /dev/dri -p 88888:88888 --device /dev/kfd --group-add video ghcr.io/rjmalagon/llama.cpp-linux-cluster-amd-apu:vulkan-latest --rpc -H 0.0.0.0 -p 88888
```

You can read more about RPC on https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
