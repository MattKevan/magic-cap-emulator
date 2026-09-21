#include "emu.h"

#include "drivenum.h"

GAME_EXTERN(___empty);
GAME_EXTERN(datarover840);
GAME_EXTERN(datarover840d);
GAME_EXTERN(datarover840f);
GAME_EXTERN(datarover840j);

game_driver const *const driver_list::s_drivers_sorted[5] =
{
	&GAME_NAME(___empty),
	&GAME_NAME(datarover840),
	&GAME_NAME(datarover840d),
	&GAME_NAME(datarover840f),
	&GAME_NAME(datarover840j),
};

std::size_t const driver_list::s_driver_count = 5;
