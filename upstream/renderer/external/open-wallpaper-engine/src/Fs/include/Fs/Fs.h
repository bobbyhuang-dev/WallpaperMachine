#pragma once
#include <memory>

#include "IBinaryStream.h"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
namespace fs
{

class Fs : NoCopy,NoMove {
public:
	virtual bool Contains(std::string_view path) const = 0;
	virtual std::shared_ptr<IBinaryStream> Open(std::string_view path) = 0;
	virtual std::shared_ptr<IBinaryStreamW> OpenW(std::string_view path) = 0;
	/// Publishes a file already written at `from` under the name `to`, in one
	/// step, replacing whatever was there.
	///
	/// A file system that cannot do this says so rather than approximating it,
	/// and the caller writes in place instead. Nothing depends on the
	/// atomicity for correctness -- a half-written cache entry is rejected when
	/// it is read -- but a reader that never sees one is cheaper than a reader
	/// that has to recover from one.
	virtual bool Rename(std::string_view from, std::string_view to) {
		(void)from;
		(void)to;
		return false;
	}
public:
	Fs() = default;
	virtual ~Fs() = default;
};

}
}
