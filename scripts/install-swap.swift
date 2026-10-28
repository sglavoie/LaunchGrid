import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: install-swap.swift STAGED_APP DESTINATION_APP\n", stderr)
    exit(2)
}

let stage = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
var info = stat()
let destinationExists = lstat(destination, &info) == 0
if !destinationExists && errno != ENOENT {
    perror("Could not inspect installed LaunchGrid")
    exit(1)
}
let result = destinationExists
    ? renameatx_np(AT_FDCWD, stage, AT_FDCWD, destination, UInt32(RENAME_SWAP))
    : rename(stage, destination)
guard result == 0 else {
    perror("Could not install LaunchGrid")
    exit(1)
}
