/* ------------------------------------------------------------------------
 *
 * dsm_array.c
 *		Allocate data in shared memory
 *
 * Copyright (c) 2015-2016, Postgres Professional
 *
 * ------------------------------------------------------------------------
 */

#include "pathman.h"
#include "dsm_array.h"

#include "storage/shmem.h"
#include "storage/dsm.h"


static dsm_segment *segment = NULL;

typedef struct DsmConfig
{
	dsm_handle	segment_handle;
	size_t		block_size;
	size_t		blocks_count;
	size_t		first_free;
} DsmConfig;

static DsmConfig *dsm_cfg = NULL;


/*
 * Block header
 *
 * Its size must be equal to 4 bytes for 32bit and 8 bytes for 64bit.
 * Otherwise it could screw up an alignment (for example on Sparc9)
 */
typedef uintptr_t BlockHeader;
typedef BlockHeader* BlockHeaderPtr;

#define FREE_BIT 0x80000000
#define is_free(header) \
	((*header) & FREE_BIT)
#define set_free(header) \
	((*header) | FREE_BIT)
#define set_used(header) \
	((*header) & ~FREE_BIT)
#define get_length(header) \
	((*header) & ~FREE_BIT)
#define set_length(header, length) \
	((length) | ((*header) & FREE_BIT))

/*
 * Amount of memory that need to be requested
 * for shared memory to store dsm config
 */
Size
estimate_dsm_config_size()
{
	return (Size) MAXALIGN(sizeof(DsmConfig));
}

/*
 * Initialize dsm config for arrays
 */
void
init_dsm_config()
{
	bool found;
	dsm_cfg = ShmemInitStruct("pathman dsm_array config", sizeof(DsmConfig), &found);
	if (!found)
	{
		dsm_cfg->segment_handle = 0;
		dsm_cfg->block_size = 0;
		dsm_cfg->blocks_count = INITIAL_BLOCKS_COUNT;
		dsm_cfg->first_free = 0;
	}
}

/*
 * Attach process to dsm_array segment. This function is used for
 * background workers only. Use init_dsm_segment() in backend processes.
 */
void
attach_dsm_array_segment()
{
	segment = dsm_attach(dsm_cfg->segment_handle);
}

/*
 * Initialize dsm segment. Returns true if new segment was created and
 * false if attached to existing segment
 */
bool
init_dsm_segment(size_t blocks_count, size_t block_size)
{
	bool ret;

	/* if there is already an existing segment then attach to it */
	if (dsm_cfg->segment_handle != 0)
	{
		ret = false;
		segment = dsm_attach(dsm_cfg->segment_handle);
	}

	/*
	 * If segment hasn't been created yet or has already been destroyed
	 * (it happens when last session detaches segment) then create new one
	 */
	if (dsm_cfg->segment_handle == 0 || segment == NULL)
	{
		/* create segment */
		segment = dsm_create(block_size * blocks_count, 0);
		dsm_cfg->segment_handle = dsm_segment_handle(segment);
		dsm_cfg->first_free = 0;
		dsm_cfg->block_size = block_size;
		dsm_cfg->blocks_count = blocks_count;
		init_dsm_table(block_size, 0, dsm_cfg->blocks_count);
		ret = true;
	}

	/*
	 * Keep mapping till the end of the session. Otherwise it would be
	 * destroyed by the end of transaction
	 */
	dsm_pin_mapping(segment);

	return ret;
}

/*
 * Initialize allocated segment with block structure
 */
void
init_dsm_table(size_t block_size, size_t start, size_t end)
{
	size_t			i;
	BlockHeaderPtr	header;
	char		   *ptr = dsm_segment_address(segment);

	/* create blocks */
	for (i = start; i < end; i++)
	{
		header = (BlockHeaderPtr) &ptr[i * block_size];
		*header = set_free(header);
		*header = set_length(header, 1);
	}

	return;
}

/*
 * Allocate array inside dsm_segment
 */
void
alloc_dsm_array(DsmArray *arr, size_t entry_size, size_t elem_count)
{
	size_t	i = 0;
	size_t	size_requested = entry_size * elem_count;
	size_t	min_pos = 0;
	size_t	max_pos = 0;
	bool	found = false;
	bool	collecting_blocks = false;
	size_t	offset = -1;
	size_t	total_length = 0;
	BlockHeaderPtr header;
	char   *ptr = dsm_segment_address(segment);

	arr->entry_size = entry_size;

	for (i = dsm_cfg->first_free; i < dsm_cfg->blocks_count; )
	{
		header = (BlockHeaderPtr) &ptr[i * dsm_cfg->block_size];
		if (is_free(header))
		{
			if (!collecting_blocks)
			{
				offset = i * dsm_cfg->block_size;
				total_length = dsm_cfg->block_size - sizeof(BlockHeader);
				min_pos = i;
				collecting_blocks = true;
			}
			else
			{
				total_length += dsm_cfg->block_size;
			}
			i++;
		}
		else
		{
			collecting_blocks = false;
			offset = 0;
			total_length = 0;
			i += get_length(header);
		}

		if (total_length >= size_requested)
		{
			max_pos = i-1;
			found = true;
			break;
		}
	}

	/*
	 * If dsm segment size is not enough then resize it (or allocate bigger
	 * for segment SysV and Windows, not implemented yet)
	 */
	if (!found)
	{
		size_t new_blocks_count = dsm_cfg->blocks_count * 2;

		dsm_resize(segment, new_blocks_count * dsm_cfg->block_size);
		init_dsm_table(dsm_cfg->block_size, dsm_cfg->blocks_count, new_blocks_count);
		dsm_cfg->blocks_count = new_blocks_count;

		/* try again */
		return alloc_dsm_array(arr, entry_size, elem_count);
	}

	/* look up for first free block */
	if (dsm_cfg->first_free == min_pos)
	{
		for (; i<dsm_cfg->blocks_count; )
		{
			header = (BlockHeaderPtr) &ptr[i * dsm_cfg->block_size];
			if (is_free(header))
			{
				dsm_cfg->first_free = i;
				break;
			}
			else
			{
				i += get_length(header);
			}
		}
	}

	/* if we found enough of space */
	if (total_length >= size_requested)
	{
		header = (BlockHeaderPtr) &ptr[min_pos * dsm_cfg->block_size];
		*header = set_used(header);
		*header = set_length(header, max_pos - min_pos + 1);

		arr->offset = offset;
		arr->elem_count = elem_count;
	}
}

void
free_dsm_array(DsmArray *arr)
{
	size_t			i = 0,
					start = arr->offset / dsm_cfg->block_size;
	char		   *ptr = dsm_segment_address(segment);
	BlockHeaderPtr	header = (BlockHeaderPtr) &ptr[start * dsm_cfg->block_size];
	size_t			blocks_count = get_length(header);

	/* set blocks free */
	for(; i < blocks_count; i++)
	{
		header = (BlockHeaderPtr) &ptr[(start + i) * dsm_cfg->block_size];
		*header = set_free(header);
		*header = set_length(header, 1);
	}

	if (start < dsm_cfg->first_free)
		dsm_cfg->first_free = start;

	arr->offset = 0;
	arr->elem_count = 0;
}

void
resize_dsm_array(DsmArray *arr, size_t entry_size, size_t elem_count)
{
	void *array_data;
	size_t array_data_size;
	void *buffer;

	/* Copy data from array to temporary buffer */
	array_data = dsm_array_get_pointer(arr, false);
	array_data_size = arr->elem_count * entry_size;
	buffer = palloc(array_data_size);
	memcpy(buffer, array_data, array_data_size);

	/* Free array */
	free_dsm_array(arr);

	/* Allocate new array */
	alloc_dsm_array(arr, entry_size, elem_count);

	/* Copy data to new array */
	array_data = dsm_array_get_pointer(arr, false);
	memcpy(array_data, buffer, array_data_size);

	pfree(buffer);
}

void *
dsm_array_get_pointer(const DsmArray *arr, bool copy)
{
	uint8  *segment_address,
		   *dsm_array,
		   *result;
	size_t	size;

	segment_address = (uint8 *) dsm_segment_address(segment);
	dsm_array = segment_address + arr->offset + sizeof(BlockHeader);

	if (copy)
	{
		size = arr->elem_count * arr->entry_size;
		result = palloc(size);
		memcpy((void *) result, (void *) dsm_array, size);
	}
	else
		result = dsm_array;

	return result;
}
