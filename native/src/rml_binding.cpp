/*
 * Copyright 2025 Rive
 */

// Markup (.rml) conversion, both directions. Export: the editor already
// builds .rev bytes for backup export; revToRml converts those, in memory,
// into the markup document -- the same conversion rive_rml_generator performs
// on files. Import: rmlToRev compiles a markup document back into .rev bytes,
// which is how the editor turns a committed .rml (its bundled TextInput
// library) into the bytes the library machinery expects.

#include "rive_native/external.hpp"

#include "rive/core/binary_reader.hpp"
#include "rive/span.hpp"
#include "rml/rml.hpp"
#include "src/rev_to_core_loader.hpp"
#include "src/core_to_rml_exporter.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// The converted document on its way to Dart: malloc'd utf-8 bytes the caller
// copies out and then hands to freeRmlExport.
struct RmlExportResponse
{
#ifdef __EMSCRIPTEN__
    WasmPtr data;
#else
    uint8_t* data;
#endif
    size_t size;
};

// The compiled rev on its way to Dart, or the errors that stopped it: exactly
// one of the two pairs is set. `error` is utf-8 "<line>: <message>\n" per
// error -- the compiler's own, in the order it reported them, then a line for
// each file= this converter could not read. Both buffers are malloc'd; the
// caller copies them out and then hands the response to freeRmlCompile.
struct RmlCompileResponse
{
#ifdef __EMSCRIPTEN__
    WasmPtr data;
    size_t size;
    WasmPtr error;
    size_t errorSize;
#else
    uint8_t* data;
    size_t size;
    char* error;
    size_t errorSize;
#endif
};

// Copies `size` bytes into a fresh malloc'd buffer the caller frees, and
// reports it through the response's (pointer, size) pair. False leaves the
// pair as it found it: nothing to copy, or nothing to copy into.
template <typename T>
static bool copyOut(const void* source, size_t size, T* data, size_t* outSize)
{
    if (source == nullptr || size == 0)
    {
        return false;
    }
    void* buffer = malloc(size);
    if (buffer == nullptr)
    {
        return false;
    }
    memcpy(buffer, source, size);
    // T is the response's pointer field: a real pointer natively, a WasmPtr
    // under emscripten, where pointers are the 32 bits that cast holds.
    *data = (T)buffer;
    *outSize = size;
    return true;
}

// Converts rev bytes to markup, leaving every payload embedded: an export has
// nowhere to put sibling files, so external-file mode is not offered here.
static bool revToRmlInternal(const uint8_t* bytes,
                             size_t length,
                             RmlExportResponse* response)
{
    if (bytes == nullptr || length == 0 || response == nullptr)
    {
        return false;
    }
    rive::BinaryReader reader(rive::Span<const uint8_t>(bytes, length));
    rive::rml::RevToCoreLoader rev;
    if (!rev.read(reader))
    {
        return false;
    }
    std::string rml =
        rive::rml::CoreToRmlExporter(rev.objects()).writeRmlDocument().rml;
    if (rml.empty())
    {
        return false;
    }
    return copyOut(rml.data(), rml.size(), &response->data, &response->size);
}

static void freeRmlExportInternal(RmlExportResponse* response)
{
    if (response == nullptr || response->data == 0)
    {
        return;
    }
    free(reinterpret_cast<void*>(response->data));
    response->data = 0;
    response->size = 0;
}

// Collects the compiled rev in memory. Nothing can be read back: a file=
// reference resolves against a directory this binding does not have, so every
// read is recorded and answered with no bytes.
//
// The record is what makes the miss visible. rml treats an empty read as "this
// asset has no contents" and still writes a successful rev (see resolveBytes /
// resolveSource in rml.cpp), so a document with file= would otherwise compile
// to a document quietly missing its payloads.
class EmbeddedCompileIO : public rive::rml::CompileIO
{
public:
    std::vector<uint8_t> bytes;
    std::vector<std::string> unreadableFiles;

    bool write(rive::Span<uint8_t> value) override
    {
        bytes.assign(value.begin(), value.end());
        return true;
    }

    std::vector<uint8_t> read(std::string filename) override
    {
        if (std::find(unreadableFiles.begin(),
                      unreadableFiles.end(),
                      filename) == unreadableFiles.end())
        {
            unreadableFiles.push_back(filename);
        }
        return std::vector<uint8_t>();
    }
};

// Compiles a markup document into rev bytes. Every payload has to be embedded
// in the document: no AssetPayloads are supplied, and a file= reference has no
// directory to resolve against, so both are reported as errors rather than
// dropped.
static void rmlToRevInternal(const uint8_t* bytes,
                             size_t length,
                             RmlCompileResponse* response)
{
    if (response == nullptr)
    {
        return;
    }
    response->data = 0;
    response->size = 0;
    response->error = 0;
    response->errorSize = 0;
    if (bytes == nullptr || length == 0)
    {
        return;
    }
    EmbeddedCompileIO io;
    auto result = rive::rml::toRev(
        std::string(reinterpret_cast<const char*>(bytes), length),
        io);
    std::string message;
    for (const rive::rml::Error& error : result.errors())
    {
        message += std::to_string(error.line());
        message += ": ";
        message += error.message();
        message += "\n";
    }
    // Reported alongside the compiler's own errors, not instead of them: the
    // compile that skipped these payloads is the one rml called a success.
    for (const std::string& filename : io.unreadableFiles)
    {
        message += "0: referenced file cannot be read here, embed it in the "
                   "markup instead: ";
        message += filename;
        message += "\n";
    }
    if (!message.empty())
    {
        copyOut(message.data(),
                message.size(),
                &response->error,
                &response->errorSize);
        return;
    }
    if (io.bytes.empty())
    {
        // A compile that reports no error and writes nothing: the caller gets
        // a message rather than an empty success it would have to interpret.
        const char* message = "0: markup compiled to no bytes\n";
        copyOut(message,
                strlen(message),
                &response->error,
                &response->errorSize);
        return;
    }
    copyOut(io.bytes.data(), io.bytes.size(), &response->data, &response->size);
}

static void freeRmlCompileInternal(RmlCompileResponse* response)
{
    if (response == nullptr)
    {
        return;
    }
    if (response->data != 0)
    {
        free(reinterpret_cast<void*>(response->data));
        response->data = 0;
    }
    if (response->error != 0)
    {
        free(reinterpret_cast<void*>(response->error));
        response->error = 0;
    }
    response->size = 0;
    response->errorSize = 0;
}

#ifndef __EMSCRIPTEN__
EXPORT bool revToRml(const uint8_t* bytes,
                     SizeType length,
                     RmlExportResponse* response)
{
    return revToRmlInternal(bytes, (size_t)length, response);
}

EXPORT void freeRmlExport(RmlExportResponse* response)
{
    freeRmlExportInternal(response);
}

EXPORT void rmlToRev(const uint8_t* bytes,
                     SizeType length,
                     RmlCompileResponse* response)
{
    rmlToRevInternal(bytes, (size_t)length, response);
}

EXPORT void freeRmlCompile(RmlCompileResponse* response)
{
    freeRmlCompileInternal(response);
}
#endif

#ifdef __EMSCRIPTEN__
#include <emscripten/bind.h>

static RmlExportResponse revToRmlWasm(WasmPtr bufferPtr, WasmPtr length)
{
    RmlExportResponse response = {0, 0};
    revToRmlInternal((const uint8_t*)bufferPtr, (size_t)length, &response);
    return response;
}

static void freeRmlExportWasm(RmlExportResponse response)
{
    freeRmlExportInternal(&response);
}

static RmlCompileResponse rmlToRevWasm(WasmPtr bufferPtr, WasmPtr length)
{
    RmlCompileResponse response = {0, 0, 0, 0};
    rmlToRevInternal((const uint8_t*)bufferPtr, (size_t)length, &response);
    return response;
}

static void freeRmlCompileWasm(RmlCompileResponse response)
{
    freeRmlCompileInternal(&response);
}

EMSCRIPTEN_BINDINGS(RiveRml)
{
    emscripten::value_object<RmlExportResponse>("RmlExportResponse")
        .field("data", &RmlExportResponse::data)
        .field("size", &RmlExportResponse::size);
    emscripten::function("revToRmlWasm", &revToRmlWasm);
    emscripten::function("freeRmlExportWasm", &freeRmlExportWasm);

    emscripten::value_object<RmlCompileResponse>("RmlCompileResponse")
        .field("data", &RmlCompileResponse::data)
        .field("size", &RmlCompileResponse::size)
        .field("error", &RmlCompileResponse::error)
        .field("errorSize", &RmlCompileResponse::errorSize);
    emscripten::function("rmlToRevWasm", &rmlToRevWasm);
    emscripten::function("freeRmlCompileWasm", &freeRmlCompileWasm);
}
#endif
