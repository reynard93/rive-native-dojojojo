#include "rive_native/rive_binding.hpp"
#include "rive_native/external.hpp"
#include "rive/text/text_selection_controller.hpp"
#include "rive/file.hpp"

// The bridge owns the root instance while in use. Descendant Text destruction
// unregisters from the controller, so a stale numeric token cannot dereference
// a removed nested instance.
struct NativeTextSelection
{
    rive::rcp<WrappedArtboard> root;
    rive::TextSelectionController controller;
    std::vector<uint32_t> ids;
    rive::SelectionStyle style;
};

EXPORT NativeTextSelection* textSelectionCreate(WrappedArtboard* root)
{
    if (root == nullptr)
        return nullptr;
    return new NativeTextSelection{rive::ref_rcp(root), {}, {}, {}};
}

EXPORT void textSelectionDelete(NativeTextSelection* region) { delete region; }

static const rive::SelectionStyle& defaultStyle(NativeTextSelection* region)
{
    static const rive::SelectionStyle defaults;
    auto file = region->root->artboard()->file();
    auto* style = file == nullptr ? nullptr : file->selectionStyle();
    return style == nullptr ? defaults : *style;
}

EXPORT uint32_t textSelectionDefaultColor(NativeTextSelection* region)
{
    return defaultStyle(region).highlightColor();
}

EXPORT float textSelectionDefaultRadius(NativeTextSelection* region)
{
    return defaultStyle(region).cornerRadius();
}

EXPORT uint32_t textSelectionRefresh(NativeTextSelection* region)
{
    region->controller.synchronize(region->root->artboard());
    region->ids = region->controller.targetIds();
    return (uint32_t)region->ids.size();
}

EXPORT uint32_t textSelectionTargetId(NativeTextSelection* region,
                                      uint32_t index)
{
    return index < region->ids.size() ? region->ids[index] : 0;
}

EXPORT bool textSelectionTargetBounds(NativeTextSelection* region,
                                      uint32_t id,
                                      float* bounds)
{
    auto* text = region->controller.target(id);
    if (!region->controller.isEligible(text))
        return false;
    auto b = region->controller.rootBounds(text);
    bounds[0] = b.minX;
    bounds[1] = b.minY;
    bounds[2] = b.maxX;
    bounds[3] = b.maxY;
    return !b.isEmptyOrNaN();
}

EXPORT const char* textSelectionTargetSource(NativeTextSelection* region,
                                             uint32_t id)
{
    return toCString(
        region->controller.sourceText(region->controller.target(id)));
}

EXPORT int32_t textSelectionTargetHit(NativeTextSelection* region,
                                      uint32_t id,
                                      float x,
                                      float y,
                                      bool nearest,
                                      float* distance)
{
    uint32_t offset = 0;
    return region->controller.hitTest(region->controller.target(id),
                                      rive::Vec2D(x, y),
                                      nearest,
                                      offset,
                                      *distance)
               ? (int32_t)offset
               : -1;
}

EXPORT void textSelectionTargetRange(NativeTextSelection* region,
                                     uint32_t id,
                                     uint32_t start,
                                     uint32_t end,
                                     uint32_t color,
                                     float radius)
{
    region->style.highlightColor(color);
    region->style.cornerRadius(radius);
    region->controller.style(&region->style);
    region->controller.setRange(region->controller.target(id), start, end);
}
