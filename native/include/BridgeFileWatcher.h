// SPDX-License-Identifier: Unlicense
#pragma once
#include <Windows.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string_view>

namespace best_of_hands {
// One outstanding directory notification, filtered to our four live files.
// Unrelated mods may wake the wait but never cause bridge reads or scans.
class BridgeFileWatcher {
public:
    enum : unsigned { Actions = 1, Handshake = 2, Client = 4, Status = 8, All = 15 };
    explicit BridgeFileWatcher(std::filesystem::path directory) : directory_(std::move(directory)) {}
    ~BridgeFileWatcher() { Close(); }
    BridgeFileWatcher(BridgeFileWatcher const&) = delete;
    BridgeFileWatcher& operator=(BridgeFileWatcher const&) = delete;
    static unsigned Classify(std::wstring_view name)
    {
        if (name == L"BestOfHandsNative.actions") return Actions;
        if (name == L"BestOfHandsNative.handshake") return Handshake;
        if (name == L"BestOfHandsNative.client") return Client;
        if (name == L"BestOfHandsNative.status") return Status;
        return 0;
    }
    unsigned Poll(DWORD timeout)
    {
        auto const now = GetTickCount64();
        if (directoryHandle_ == INVALID_HANDLE_VALUE) {
            if (now < retryAfter_) { Sleep(timeout); return 0; }
            retryAfter_ = now + 2000;
            if (!Open()) { Sleep(timeout); return All; }
            // Reconcile once after notification storage recovers.
            return All;
        }
        auto const wait = WaitForSingleObject(overlapped_.hEvent, timeout);
        if (wait == WAIT_TIMEOUT) return 0;
        DWORD bytes{};
        if (wait != WAIT_OBJECT_0 || !GetOverlappedResult(directoryHandle_, &overlapped_, &bytes, FALSE)) {
            Close();
            return All;
        }
        unsigned changed = bytes == 0 ? All : 0; // overflow: reconcile all
        std::size_t offset{};
        while (offset + offsetof(FILE_NOTIFY_INFORMATION, FileName) <= bytes) {
            auto const* entry = reinterpret_cast<FILE_NOTIFY_INFORMATION const*>(buffer_.data() + offset);
            if (entry->FileNameLength > bytes - offset - offsetof(FILE_NOTIFY_INFORMATION, FileName)) {
                changed = All;
                break;
            }
            changed |= Classify({entry->FileName, entry->FileNameLength / sizeof(wchar_t)});
            if (!entry->NextEntryOffset) break;
            if (entry->NextEntryOffset > bytes - offset) { changed = All; break; }
            offset += entry->NextEntryOffset;
        }
        if (!Arm()) { Close(); return All; }
        return changed;
    }
private:
    bool Open()
    {
        directoryHandle_ = CreateFileW(directory_.c_str(), FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, nullptr);
        if (directoryHandle_ == INVALID_HANDLE_VALUE) return false;
        overlapped_.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!overlapped_.hEvent || !Arm()) { Close(); return false; }
        return true;
    }
    bool Arm()
    {
        ResetEvent(overlapped_.hEvent);
        return ReadDirectoryChangesW(directoryHandle_, buffer_.data(), static_cast<DWORD>(buffer_.size()), FALSE,
            FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE,
            nullptr, &overlapped_, nullptr) != FALSE;
    }
    void Close()
    {
        if (directoryHandle_ != INVALID_HANDLE_VALUE) {
            CancelIoEx(directoryHandle_, &overlapped_);
            // Keep the OVERLAPPED and buffer alive until cancellation completes.
            DWORD ignored{};
            GetOverlappedResult(directoryHandle_, &overlapped_, &ignored, TRUE);
            CloseHandle(directoryHandle_);
            directoryHandle_ = INVALID_HANDLE_VALUE;
        }
        if (overlapped_.hEvent) CloseHandle(overlapped_.hEvent);
        overlapped_ = {};
    }
    std::filesystem::path directory_;
    HANDLE directoryHandle_{INVALID_HANDLE_VALUE};
    OVERLAPPED overlapped_{};
    alignas(DWORD) std::array<std::byte, 16384> buffer_{};
    ULONGLONG retryAfter_{};
};
} // namespace best_of_hands
