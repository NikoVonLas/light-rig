#include <assert.h>
#include <string.h>
#include "ptp_codec.h"

int main(void)
{
    uint8_t command[32];
    uint32_t session = 1;
    assert(ptp_encode_command(command, sizeof(command), 0x1002, 0, &session, 1) == 16);
    ptp_container_header_t header;
    assert(ptp_decode_header(command, 16, &header));
    assert(header.code == 0x1002 && header.type == 1 && header.transaction_id == 0);
    assert(!ptp_decode_header(command, 15, &header));
    assert(!ptp_encode_command(command, 12, 0x1002, 0, &session, 1));
    // Fixed fields, empty extension string, functional mode, five empty arrays,
    // manufacturer "C", model "M", version "1", empty serial.
    uint8_t data[47] = {0};
    data[31] = 2; data[32] = 'C';
    data[36] = 2; data[37] = 'M';
    data[41] = 2; data[42] = '1';
    ptp_device_info_t info;
    assert(ptp_decode_device_info(data, sizeof(data), &info));
    assert(!strcmp(info.model, "M") && !strcmp(info.manufacturer, "C"));
    assert(!strcmp(info.version, "1") && info.operation_count == 0);
    for (size_t n = 0; n < sizeof(data); n++) assert(!ptp_decode_device_info(data, n, &info));
    data[11] = 255; data[12] = 255; data[13] = 255; data[14] = 255;
    assert(!ptp_decode_device_info(data, sizeof(data), &info));
    memset(data + 11, 0, 4);
    data[31] = 255;
    assert(!ptp_decode_device_info(data, sizeof(data), &info));
    data[31] = 2; data[34] = 'X'; // Missing UTF-16 terminator.
    assert(!ptp_decode_device_info(data, sizeof(data), &info));
    return 0;
}
