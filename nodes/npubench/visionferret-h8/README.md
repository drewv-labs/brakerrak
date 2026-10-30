<div align="center">

# VisionFerret-H8(L)

*StarFive VisionFive 2 RISC-V Hailo-8(L) Edge AI/ML NPU Inference Engine*

</div>

The Hailo-8(L) Edge AI NPU Inference Engine is a powerful tool for developers and businesses looking to deploy edge AI/ML solutions that require high performance, low power consumption, and versatility. Its compatibility with various edge computing platforms and support for a wide range of AI algorithms make it an ideal choice for a variety of applications.  


Key features of `VisionFerret-H8(L)` RISC-V powered Hailo-8(L) Edge AI NPU Inference Engine include:

- **High Performance**: The Hailo-8(L) NPU delivers up to 26 TOPS (13 TOPS for Hailo-8L variant) (Tensor Operations Per Second) of performance, making it one of the most powerful NPU solutions for edge AI.
- **Versatile AI Algorithms**: The engine supports a variety of AI algorithms, including convolutional neural networks (CNNs), recurrent neural networks (RNNs), and transformers, making it suitable for different types of edge AI workloads.
- **Real-Time Performance**: With its high performance and low power consumption, the engine can deliver real-time AI inference, enabling applications that require immediate responses.
- **Secure and Scalable**: The RISC-V architecture and secure design of the engine ensure that it is suitable for applications that require high security and scalability.

---

## Usage
The `forge-visionferret-h8.sh` build script serves as the single entrypoint for provisioning nodes. Run the script as your standard user, as it internally escalates to `sudo` when necessary.

**Standard Provisioning**
To run the generic core setup:
```bash
./forge-visionferret-h8.sh --all
```

**Headless Tailscale Mesh**
To run the core setup and install Tailscale:
```bash
./forge-visionferret-h8.sh --all --tailscale
```

**Granular Stage Execution**
You can execute individual phases manually if a kernel update forces a reboot mid-process:
*   `--core`: Executes `run_core()` for system locales, APT sources, and OS de-bloating.
*   `--driver`: Executes `run_driver()` to compile and install the PCIe driver and firmware.
*   `--api`: Executes `run_api()` to compile the HailoRT C++ API and `pyhailort` wheel.
*   `--uv`: Executes `run_uv()` to install the Astral `uv` tool.
*   `--tailscale`: Executes `run_tailscale()` to install Tailscale and enable zero-trust SSH.

---

```python
# Example of using the Hailo-8(L) Edge AI NPU Inference Engine for image recognition

class Hailo8LInferenceEngine:
    def __init__(self):
        self.npu = "Hailo-8(L)"
        self.top_performance = 26  # TOPS
        self.low_power_consumption = True

    def run_inference(self, image):
        # Simulate running inference on an image
        print(f"Running inference on image using {self.npu} NPU.")
        # Simulate processing time
        import time
        time.sleep(0.1)
        return "Object detected: Cat"

# Create an instance of the inference engine
engine = Hailo8LInferenceEngine()

# Simulate running inference on an image
result = engine.run_inference("path_to_image.jpg")
print(result)
```

This code snippet demonstrates how to use the RISC-V Hailo-8(L) Edge AI NPU Inference Engine for image recognition. The `Hailo8LInferenceEngine` class simulates the engine's capabilities, including running inference on an image and simulating the processing time. The example shows how to create an instance of the engine and run inference on an image, simulating the detection of an object.


---

<div align="center">

**DREW-V LABS** // **Drew Vandagriff** — *Dallas, TX*  
`Simplicity in Architecture · Efficiency in Engineering · Purity in Science · Audacity in Art · Life in Logic`

</div>
