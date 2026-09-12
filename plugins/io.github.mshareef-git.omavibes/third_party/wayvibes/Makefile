TARGET = wayvibes

SRC = src/main.cpp src/audio.cpp src/device.cpp src/config.cpp src/analytics.cpp
INC = -Isrc
CXXFLAGS = -std=c++17 $(INC)
LIBS = -levdev

all: $(TARGET)

$(TARGET): $(SRC) src/miniaudio.h
	g++ $(CXXFLAGS) -o $(TARGET) $(SRC) $(LIBS) --verbose

install: $(TARGET)
	install -Dm755 $(TARGET) -t /usr/local/bin

uninstall:
	rm -f /usr/local/bin/$(TARGET)

clean:
	rm -f $(TARGET)

.PHONY: all install clean uninstall
