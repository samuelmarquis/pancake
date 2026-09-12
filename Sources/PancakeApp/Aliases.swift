import PancakeCore

// `Port` collides with Foundation's NSPort (imported via AppKit/Foundation). Pin the bare name to
// the graph's Port for the whole PancakeApp module, declared once here so every file agrees.
typealias Port = PancakeCore.Port
