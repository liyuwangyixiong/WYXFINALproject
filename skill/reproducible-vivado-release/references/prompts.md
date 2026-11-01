# Evidence audit prompt

Use this template when moving a design from one computer to another:

> Inspect this Vivado repository and the bitstream that will be distributed. Identify the tool version, FPGA part, top, source files, generated IP, constraints, build scripts and exact binary hash. For each claim, separate source presence, simulation, synthesis, implementation, bit generation and physical board validation. Quote actual resource and timing numbers from reports. Flag missing or mismatched evidence, private data, unsafe paths and files without confirmed redistribution rights. Do not invent measurements or change algorithms during this audit.

The model's response should be an evidence table with file paths and a short list of gates that remain pending. Reuse the template for other FPGA applications after replacing only the repository and target device context.
