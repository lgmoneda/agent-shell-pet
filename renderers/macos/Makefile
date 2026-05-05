SWIFTC ?= swiftc
TARGET := agent-shell-pet-macos-renderer
SOURCES := Sources/AgentShellPetRenderer/main.swift

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(SWIFTC) -O -framework AppKit -o $@ $(SOURCES)

clean:
	rm -f $(TARGET)
