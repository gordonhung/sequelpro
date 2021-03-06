//
//  SPTableContentFilterController.m
//  sequel-pro
//
//  Created by Max Lohrmann on 04.05.18.
//  Copyright (c) 2018 Max Lohrmann. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.
//
//  More info at <https://github.com/sequelpro/sequelpro>

#import "SPTableContentFilterController.h"
#import "SPTableContent.h"
#import "SPQueryController.h"
#import "SPDatabaseDocument.h"
#import "RegexKitLite.h"
#import "SPContentFilterManager.h"
#import "SPFunctions.h"
#import "SPTableFilterParser.h"

typedef NS_ENUM(NSInteger, RuleNodeType) {
	RuleNodeTypeColumn,
	RuleNodeTypeString,
	RuleNodeTypeOperator,
	RuleNodeTypeArgument,
	RuleNodeTypeConnector,
};

NSString * const SPTableContentFilterHeightChangedNotification = @"SPTableContentFilterHeightChanged";

const NSString * const SerFilterClass = @"filterClass";
const NSString * const SerFilterClassGroup = @"groupNode";
const NSString * const SerFilterClassExpression = @"expressionNode";
const NSString * const SerFilterGroupIsConjunction = @"isConjunction";
const NSString * const SerFilterGroupChildren = @"children";
/**
 * The name of the column to filter in (left side expression)
 *
 * Legacy names:
 *   @"filterField", fieldField
 */
const NSString * const SerFilterExprColumn = @"column";
/**
 * The data type grouping of the column for applicable filters
 */
const NSString * const SerFilterExprType = @"filterType";
/**
 * The title of the filter operator to apply
 *
 * Legacy names:
 *   @"filterComparison", compareField
 */
const NSString * const SerFilterExprComparison = @"filterComparison";
/**
 * The values to apply the filter with
 *
 * Legacy names:
 *   @"filterValue", argumentField
 *   @"firstBetweenField", @"secondBetweenField", firstBetweenField, secondBetweenField
 */
const NSString * const SerFilterExprValues = @"filterValues";
/**
 * the filter definition dictionary (as in ContentFilters.plist)
 *
 * This item is not designed to be serialized to disk
 */
const NSString * const SerFilterExprDefinition = @"filterDefinition";

@interface RuleNode : NSObject {
	RuleNodeType type;
}
@property(assign, nonatomic) RuleNodeType type;
@end

@implementation RuleNode

@synthesize type = type;

- (NSUInteger)hash {
	return type;
}

- (BOOL)isEqual:(id)other {
	if (other == self) return YES;
	if (other && [[other class] isEqual:[self class]] && [(RuleNode *)other type] == type) return YES;

	return NO;
}

@end

#pragma mark -

@interface ColumnNode : RuleNode {
	NSString *name;
	NSString *typegrouping;
	NSArray *operatorCache;
}
@property(copy, nonatomic) NSString *name;
@property(copy, nonatomic) NSString *typegrouping;
@property(retain, nonatomic) NSArray *operatorCache;
@end

@implementation ColumnNode

@synthesize name = name;
@synthesize typegrouping = typegrouping;
@synthesize operatorCache = operatorCache;

- (instancetype)init
{
	if((self = [super init])) {
		type = RuleNodeTypeColumn;
	}
	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"ColumnNode<%@@%p>",[self name],self];
}

- (NSUInteger)hash {
	return ([name hash] ^ [typegrouping hash] ^ [super hash]);
}

- (BOOL)isEqual:(id)other {
	if (other == self) return YES;
	if (other && [[other class] isEqual:[self class]] && [name isEqualToString:[other name]] && [typegrouping isEqualToString:[other typegrouping]]) return YES;

	return NO;
}

@end

#pragma mark -

@interface StringNode : RuleNode {
	NSString *value;
}
@property(copy, nonatomic) NSString *value;
@end

@implementation StringNode

@synthesize value = value;

- (instancetype)init
{
	if((self = [super init])) {
		type = RuleNodeTypeString;
	}
	return self;
}

- (NSUInteger)hash {
	return ([value hash] ^ [super hash]);
}

- (BOOL)isEqual:(id)other {
	if (other == self) return YES;
	if (other && [[other class] isEqual:[self class]] && [value isEqualToString:[(StringNode *)other value]]) return YES;

	return NO;
}


@end

#pragma mark -

@interface OpNode : RuleNode {
	// Note: The main purpose of this field is to have @"=" for column A and @"=" for column B to return NO in -isEqual:
	//       because otherwise NSRuleEditor will get confused and blow up.
	ColumnNode *parentColumn;
	NSDictionary *settings;
	NSDictionary *filter;
}
@property (assign, nonatomic) ColumnNode *parentColumn;
@property (retain, nonatomic) NSDictionary *settings;
@property (retain, nonatomic) NSDictionary *filter;
@end

@implementation OpNode

@synthesize parentColumn = parentColumn;
@synthesize settings = settings;
@synthesize filter = filter;

- (instancetype)init
{
	if((self = [super init])) {
		type = RuleNodeTypeOperator;
	}
	return self;
}

- (void)dealloc
{
	[self setFilter:nil];
	[self setSettings:nil];
	[super dealloc];
}

- (NSUInteger)hash {
	return (([parentColumn hash] << 16) ^ [settings hash] ^ [super hash]);
}

- (BOOL)isEqual:(id)other {
	if (other == self) return YES;
	if (other && [[other class] isEqual:[self class]] && [settings isEqualToDictionary:[(OpNode *)other settings]] && [parentColumn isEqual:[other parentColumn]]) return YES;

	return NO;
}

@end

#pragma mark -

@interface ArgNode : RuleNode {
	NSDictionary *filter;
	NSUInteger argIndex;
	NSString *initialValue;
}
@property (copy, nonatomic) NSString *initialValue;
@property (retain, nonatomic) NSDictionary *filter;
@property (assign, nonatomic) NSUInteger argIndex;
@end

@implementation ArgNode

@synthesize filter = filter;
@synthesize argIndex = argIndex;
@synthesize initialValue = initialValue;

- (instancetype)init
{
	if((self = [super init])) {
		type = RuleNodeTypeArgument;
	}
	return self;
}

- (void)dealloc
{
	[self setInitialValue:nil];
	[self setFilter:nil];
	[super dealloc];
}

- (NSUInteger)hash {
	// initialValue does not count towards hash because two Args are not different if only the initialValue differs
	return ((argIndex << 16) ^ [filter hash] ^ [super hash]);
}

- (BOOL)isEqual:(id)other {
	// initialValue does not count towards isEqual: because two Args are not different if only the initialValue differs
	if (other == self) return YES;
	if (other && [[other class] isEqual:[self class]] && [filter isEqualToDictionary:[(ArgNode *)other filter]] && argIndex == [(ArgNode *)other argIndex]) return YES;

	return NO;
}

@end

#pragma mark -

@interface ConnectorNode : RuleNode {
	NSDictionary *filter;
	NSUInteger labelIndex;
}
@property (retain, nonatomic) NSDictionary *filter;
@property (assign, nonatomic) NSUInteger labelIndex;
@end

@implementation ConnectorNode

@synthesize filter = filter;
@synthesize labelIndex = labelIndex;

- (instancetype)init
{
	if((self = [super init])) {
		type = RuleNodeTypeConnector;
	}
	return self;
}

- (void)dealloc
{
	[self setFilter:nil];
	[super dealloc];
}

- (NSUInteger)hash {
	return ((labelIndex << 16) ^ [filter hash] ^ [super hash]);
}

- (BOOL)isEqual:(id)other {
	if (other == self) return YES;
	if (other && [[other class] isEqual:[self class]] && [filter isEqualToDictionary:[(ConnectorNode *)other filter]] && labelIndex == [(ConnectorNode *)other labelIndex]) return YES;

	return NO;
}

@end

#pragma mark -

@interface SPTableContentFilterController () <NSRuleEditorDelegate>

@property (readwrite, assign, nonatomic) CGFloat preferredHeight;

// This is the binding used by NSRuleEditor for the current state
@property (retain, nonatomic) NSMutableArray *model;

- (NSArray *)_compareTypesForColumn:(ColumnNode *)colNode;
- (IBAction)_textFieldAction:(id)sender;
- (IBAction)_editFiltersAction:(id)sender;
- (void)_contentFiltersHaveBeenUpdated:(NSNotification *)notification;
+ (NSDictionary *)_flattenSerializedFilter:(NSDictionary *)in;
static BOOL SerIsGroup(NSDictionary *dict);
- (NSDictionary *)_serializedFilterIncludingFilterDefinition:(BOOL)includeDefinition;
+ (void)_writeFilterTree:(NSDictionary *)in toString:(NSMutableString *)out wrapInParenthesis:(BOOL)wrap binary:(BOOL)isBINARY error:(NSError **)err;
- (NSMutableDictionary *)_restoreSerializedFilter:(NSDictionary *)serialized;
static void _addIfNotNil(NSMutableArray *array, id toAdd);
- (ColumnNode *)_columnForName:(NSString *)name;
- (OpNode *)_operatorNamed:(NSString *)title forColumn:(ColumnNode *)col;
- (BOOL)_focusOnFieldInSubtree:(NSDictionary *)dict;
- (void)_resize;

@end

@implementation SPTableContentFilterController

@synthesize model = model;
@synthesize preferredHeight = preferredHeight;
@synthesize target = target;
@synthesize action = action;

- (instancetype)init
{
	if((self = [super init])) {
		columns = [[NSMutableArray alloc] init];
		model = [[NSMutableArray alloc] init];
		preferredHeight = 0.0;
		target = nil;
		action = NULL;

		// Init default filters for Content Browser
		contentFilters = [[NSMutableDictionary alloc] init];
		numberOfDefaultFilters = [[NSMutableDictionary alloc] init];

		NSError *readError = nil;
		NSString *filePath = [NSBundle pathForResource:@"ContentFilters.plist" ofType:nil inDirectory:[[NSBundle mainBundle] bundlePath]];
		NSData *defaultFilterData = [NSData dataWithContentsOfFile:filePath
		                                                   options:NSMappedRead
		                                                     error:&readError];

		if(defaultFilterData && !readError) {
			NSDictionary *defaultFilterDict = [NSPropertyListSerialization propertyListWithData:defaultFilterData
			                                                                            options:NSPropertyListMutableContainersAndLeaves
			                                                                             format:NULL
			                                                                              error:&readError];

			if(defaultFilterDict && !readError) {
				[contentFilters setDictionary:defaultFilterDict];
			}
		}

		if (readError) {
			NSLog(@"Error while reading 'ContentFilters.plist':\n%@", readError);
			NSBeep();
		}
		else {
			[numberOfDefaultFilters setObject:[NSNumber numberWithInteger:[[contentFilters objectForKey:@"number"] count]] forKey:@"number"];
			[numberOfDefaultFilters setObject:[NSNumber numberWithInteger:[[contentFilters objectForKey:@"date"] count]] forKey:@"date"];
			[numberOfDefaultFilters setObject:[NSNumber numberWithInteger:[[contentFilters objectForKey:@"string"] count]] forKey:@"string"];
			[numberOfDefaultFilters setObject:[NSNumber numberWithInteger:[[contentFilters objectForKey:@"spatial"] count]] forKey:@"spatial"];
		}
	}
	return self;
}

- (void)awakeFromNib
{
	[filterRuleEditor bind:@"rows" toObject:self withKeyPath:@"model" options:nil];

	[[NSNotificationCenter defaultCenter] addObserver:self
	                                         selector:@selector(_contentFiltersHaveBeenUpdated:)
	                                             name:SPContentFiltersHaveBeenUpdatedNotification
	                                           object:nil];
}

- (void)focusFirstInputField
{
	for(NSDictionary *rootItem in model) {
		if([self _focusOnFieldInSubtree:rootItem]) return;
	}
}

- (BOOL)_focusOnFieldInSubtree:(NSDictionary *)dict
{
	//if we are a simple row we might have an input field ourself, otherwise search among our children
	if([[dict objectForKey:@"rowType"] unsignedIntegerValue] == NSRuleEditorRowTypeSimple) {
		for(id obj in [dict objectForKey:@"displayValues"]) {
			if([obj isKindOfClass:[NSTextField class]]) {
				[[(NSTextField *)obj window] makeFirstResponder:obj];
				return YES;
			}
		}
	}
	else {
		for(NSDictionary *child in [dict objectForKey:@"subrows"]) {
			if([self _focusOnFieldInSubtree:child]) return YES;
		}
	}
	return NO;
}

- (void)updateFiltersFrom:(SPTableContent *)tableContent
{
	[self willChangeValueForKey:@"model"]; // manual KVO is needed for filter rule editor to notice change
	[model removeAllObjects];
	[self didChangeValueForKey:@"model"];

	[columns removeAllObjects];

	//without a table there is nothing to filter
	if(![tableContent selectedTable]) return;

	//sort column names if enabled
	NSArray *columnDefinitions = [tableContent dataColumnDefinitions];
	if([[NSUserDefaults standardUserDefaults] boolForKey:SPAlphabeticalTableSorting]) {
		NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];
		columnDefinitions = [columnDefinitions sortedArrayUsingDescriptors:@[sortDescriptor]];
	}

	// get the columns
	for(NSDictionary *colDef in columnDefinitions) {
		ColumnNode *node = [[ColumnNode alloc] init];
		[node setName:[colDef objectForKey:@"name"]];
		[node setTypegrouping:[colDef objectForKey:@"typegrouping"]];
		[columns addObject:node];
		[node release];
	}

	// make the rule editor reload the criteria
	[filterRuleEditor reloadCriteria];
}

- (NSInteger)ruleEditor:(NSRuleEditor *)editor numberOfChildrenForCriterion:(nullable id)criterion withRowType:(NSRuleEditorRowType)rowType
{
	// nil criterion is always the first element in a row, compound rows are only for "AND"/"OR" groups
	if(!criterion && rowType == NSRuleEditorRowTypeCompound) {
		return 2;
	}
	else if(!criterion && rowType == NSRuleEditorRowTypeSimple) {
		return [columns count];
	}
	else if(rowType == NSRuleEditorRowTypeSimple) {
		// the children of the columns are their operators
		RuleNodeType type = [(RuleNode *)criterion type];
		if(type == RuleNodeTypeColumn) {
			ColumnNode *node = (ColumnNode *)criterion;
			if(![node operatorCache]) {
				NSArray *ops = [self _compareTypesForColumn:node];
				[node setOperatorCache:ops];
			}
			return [[node operatorCache] count];
		}
		// the first child of an operator is the first argument (if it has one)
		else if(type == RuleNodeTypeOperator) {
			OpNode *node = (OpNode *)criterion;
			NSInteger numOfArgs = [[[node filter] objectForKey:@"NumberOfArguments"] integerValue];
			return (numOfArgs > 0) ? 1 : 0;
		}
		// the child of an argument can only be the conjunction label if more arguments follow
		else if(type == RuleNodeTypeArgument) {
			ArgNode *node = (ArgNode *)criterion;
			NSInteger numOfArgs = [[[node filter] objectForKey:@"NumberOfArguments"] integerValue];
			return (numOfArgs > [node argIndex]+1) ? 1 : 0;
		}
		// the child of a conjunction is the next argument, if we have one
		else if(type == RuleNodeTypeConnector) {
			ConnectorNode *node = (ConnectorNode *)criterion;
			NSInteger numOfArgs = [[[node filter] objectForKey:@"NumberOfArguments"] integerValue];
			return (numOfArgs > [node labelIndex]+1) ? 1 : 0;
		}
	}
	return 0;
}

- (id)ruleEditor:(NSRuleEditor *)editor child:(NSInteger)index forCriterion:(nullable id)criterion withRowType:(NSRuleEditorRowType)rowType
{
	// nil criterion is always the first element in a row, compound rows are only for "AND"/"OR" groups
	if(!criterion && rowType == NSRuleEditorRowTypeCompound) {
		StringNode *node = [[StringNode alloc] init];
		switch(index) {
			case 0: [node setValue:@"AND"]; break;
			case 1: [node setValue:@"OR"]; break;
		}
		return [node autorelease];
	}
	// this is the column field
	else if(!criterion && rowType == NSRuleEditorRowTypeSimple) {
		return [columns objectAtIndex:index];
	}
	else if(rowType == NSRuleEditorRowTypeSimple) {
		// the children of the columns are their operators
		RuleNodeType type = [(RuleNode *) criterion type];
		if (type == RuleNodeTypeColumn) {
			return [[criterion operatorCache] objectAtIndex:index];
		}
		// the first child of an operator is the first argument
		else if(type == RuleNodeTypeOperator) {
			NSDictionary *filter = [(OpNode *)criterion filter];
			if([[filter objectForKey:@"NumberOfArguments"] integerValue]) {
				ArgNode *arg = [[ArgNode alloc] init];
				[arg setFilter:filter];
				[arg setArgIndex:0];
				return [arg autorelease];
			}
		}
		// the child of an argument can only be the conjunction label if more arguments follow
		else if(type == RuleNodeTypeArgument) {
			NSDictionary *filter = [(ArgNode *)criterion filter];
			NSUInteger argIndex = [(ArgNode *)criterion argIndex];
			if([[filter objectForKey:@"NumberOfArguments"] integerValue] > argIndex +1) {
				ConnectorNode *node = [[ConnectorNode alloc] init];
				[node setFilter:filter];
				[node setLabelIndex:argIndex]; // label 0 follows argument 0
				return [node autorelease];
			}
		}
		// the child of a conjunction is the next argument, if we have one
		else if(type == RuleNodeTypeConnector) {
			ConnectorNode *node = (ConnectorNode *)criterion;
			NSInteger numOfArgs = [[[node filter] objectForKey:@"NumberOfArguments"] integerValue];
			if(numOfArgs > [node labelIndex]+1) {
				ArgNode *arg = [[ArgNode alloc] init];
				[arg setFilter:[node filter]];
				[arg setArgIndex:([node labelIndex]+1)];
				return [arg autorelease];
			}
		}
	}
	return nil;
}

- (id)ruleEditor:(NSRuleEditor *)editor displayValueForCriterion:(id)criterion inRow:(NSInteger)row
{
	switch([(RuleNode *)criterion type]) {
		case RuleNodeTypeString: return [(StringNode *)criterion value];
		case RuleNodeTypeColumn: return [(ColumnNode *)criterion name];
		case RuleNodeTypeOperator: {
			OpNode *node = (OpNode *)criterion;
			NSMenuItem *item;
			if ([[[node settings] objectForKey:@"isSeparator"] boolValue]) {
				item = [NSMenuItem separatorItem];
			}
			else {
				item = [[NSMenuItem alloc] initWithTitle:[[node settings] objectForKey:@"title"] action:NULL keyEquivalent:@""];
				[item setToolTip:[[node settings] objectForKey:@"tooltip"]];
				[item setTag:[[[node settings] objectForKey:@"tag"] integerValue]];
				//TODO the following seems to be mentioned exactly nowhere on the internet/in documentation, but without it NSMenuItems won't work properly, even though Apple says they are supported
				[item setRepresentedObject:@{
					@"item": node,
					@"value": [item title],
					// this one is needed by the "Edit filters…" item for context
					@"filterType": SPBoxNil([[node settings] objectForKey:@"filterType"]),
				}];
				// override the default action from the rule editor if given (used to open the edit content filters sheet)
				id _target = [[node settings] objectForKey:@"target"];
				SEL _action = (SEL)[(NSValue *)[[node settings] objectForKey:@"action"] pointerValue];
				if(_target && _action) {
					[item setTarget:_target];
					[item setAction:_action];
				}
				[item autorelease];
			}
			return item;
		}
		case RuleNodeTypeArgument: {
			//an argument is a textfield
			ArgNode *node = (ArgNode *)criterion;
			NSTextField *textField = [[NSTextField alloc] init];
			[[textField cell] setSendsActionOnEndEditing:YES];
			[[textField cell] setUsesSingleLineMode:YES];
			[textField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
			[textField sizeToFit];
			[textField setTarget:self];
			[textField setAction:@selector(_textFieldAction:)];
			if([node initialValue]) [textField setStringValue:[node initialValue]];
			NSRect frame = [textField frame];
			//adjust width, to make the field wider
			frame.size.width = 500; //TODO determine a good width (possibly from the field type size) - how to access the rule editors bounds?
			[textField setFrame:frame];
			return [textField autorelease];
		}
		case RuleNodeTypeConnector: {
			// a simple string for once
			ConnectorNode *node = (ConnectorNode *)criterion;
			NSArray* labels = [[node filter] objectForKey:@"ConjunctionLabels"];
			return (labels && [labels count] == 1)? [labels objectAtIndex:0] : @"";
		}
	}
	
	return nil;
}

- (IBAction)_textFieldAction:(id)sender
{
	// if the action was caused by pressing return or enter, trigger filtering
	NSEvent *event = [NSApp currentEvent];
	if(event && [event type] == NSKeyDown && ([event keyCode] == 36 || [event keyCode] == 76)) {
		if(target && action) [target performSelector:action withObject:self];
	}
}

- (void)_resize
{
	// The situation with the sizing is a bit f'ed up:
	// - When this method is invoked the NSRuleEditor has not yet updated its required frame size
	// - We can't use KVO on -frame either, because SPTableContent will update the container size which
	//   ultimately also updates the NSRuleEditor's frame, causing a loop
	// - Calling -sizeToFit works, but only when the NSRuleEditor is growing. It won't shrink
	//   after removing rows.
	// - -intrinsicContentSize is what we want, but that method is 10.7+, so on 10.6 let's do the
	//   easiest workaround (note that both -intrinsicContentSize and -sizeToFit internally use -[NSRuleEditor _minimumFrameHeight])
	CGFloat wantsHeight;
	if([filterRuleEditor respondsToSelector:@selector(intrinsicContentSize)]) {
		NSSize sz = [filterRuleEditor intrinsicContentSize];
		wantsHeight = sz.height;
	}
	else {
		wantsHeight = [filterRuleEditor rowHeight] * [filterRuleEditor numberOfRows];
	}
	if(wantsHeight != preferredHeight) {
		[self setPreferredHeight:wantsHeight];
		[[NSNotificationCenter defaultCenter] postNotificationName:SPTableContentFilterHeightChangedNotification object:self];
	}
}

- (void)ruleEditorRowsDidChange:(NSNotification *)notification 
{
	[self performSelector:@selector(_resize) withObject:nil afterDelay:0.2]; //TODO find a better way to trigger resize
	//[self _resize];
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	SPClear(model);
	SPClear(columns);
	SPClear(contentFilters);
	SPClear(numberOfDefaultFilters);
	[super dealloc];
}

/**
 * Sets the compare types for the filter and the appropriate formatter for the textField
 */
- (NSArray *)_compareTypesForColumn:(ColumnNode *)colNode
{
	if(contentFilters == nil
		|| ![contentFilters objectForKey:@"number"]
		|| ![contentFilters objectForKey:@"string"]
		|| ![contentFilters objectForKey:@"date"]) {
		NSLog(@"Error while setting filter types.");
		NSBeep();
		return @[];
	}

	NSString *fieldTypeGrouping;
	if([colNode typegrouping]) {
		fieldTypeGrouping = [NSString stringWithString:[colNode typegrouping]];
	}
	else {
		return @[];
	}

	NSMutableArray *compareItems = [NSMutableArray array];
	
	NSString *compareType;
	
	if ( [fieldTypeGrouping isEqualToString:@"date"] ) {
		compareType = @"date";

		/*
		 if ([fieldType isEqualToString:@"timestamp"]) {
		 [argumentField setFormatter:[[NSDateFormatter alloc]
		 initWithDateFormat:@"%Y-%m-%d %H:%M:%S" allowNaturalLanguage:YES]];
		 }
		 if ([fieldType isEqualToString:@"datetime"]) {
		 [argumentField setFormatter:[[NSDateFormatter alloc] initWithDateFormat:@"%Y-%m-%d %H:%M:%S" allowNaturalLanguage:YES]];
		 }
		 if ([fieldType isEqualToString:@"date"]) {
		 [argumentField setFormatter:[[NSDateFormatter alloc] initWithDateFormat:@"%Y-%m-%d" allowNaturalLanguage:YES]];
		 }
		 if ([fieldType isEqualToString:@"time"]) {
		 [argumentField setFormatter:[[NSDateFormatter alloc] initWithDateFormat:@"%H:%M:%S" allowNaturalLanguage:YES]];
		 }
		 if ([fieldType isEqualToString:@"year"]) {
		 [argumentField setFormatter:[[NSDateFormatter alloc] initWithDateFormat:@"%Y" allowNaturalLanguage:YES]];
		 }
		 */

		// TODO: A bug in the framework previously meant enum fields had to be treated as string fields for the purposes
		// of comparison - this can now be split out to support additional comparison fucntionality if desired.
	} 
	else if ([fieldTypeGrouping isEqualToString:@"string"]   || [fieldTypeGrouping isEqualToString:@"binary"]
		|| [fieldTypeGrouping isEqualToString:@"textdata"] || [fieldTypeGrouping isEqualToString:@"blobdata"]
		|| [fieldTypeGrouping isEqualToString:@"enum"]) {

		compareType = @"string";
		// [argumentField setFormatter:nil];

	} 
	else if ([fieldTypeGrouping isEqualToString:@"bit"] || [fieldTypeGrouping isEqualToString:@"integer"]
		|| [fieldTypeGrouping isEqualToString:@"float"]) {
		compareType = @"number";
		// [argumentField setFormatter:numberFormatter];

	} 
	else if ([fieldTypeGrouping isEqualToString:@"geometry"]) {
		compareType = @"spatial";

	} 
	else  {
		compareType = @"";
		NSBeep();
		NSLog(@"ERROR: unknown type for comparision: in %@", fieldTypeGrouping);
	}

	// Add IS NULL and IS NOT NULL as they should always be available
	// [compareField addItemWithTitle:@"IS NULL"];
	// [compareField addItemWithTitle:@"IS NOT NULL"];

	// Remove user-defined filters first
	if([numberOfDefaultFilters objectForKey:compareType]) {
		NSUInteger cycles = [[contentFilters objectForKey:compareType] count] - [[numberOfDefaultFilters objectForKey:compareType] integerValue];
		while(cycles > 0) {
			[[contentFilters objectForKey:compareType] removeLastObject];
			cycles--;
		}
	}
	
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

#ifndef SP_CODA /* content filters */
	// Load global user-defined content filters
	if([prefs objectForKey:SPContentFilters]
		&& [contentFilters objectForKey:compareType]
		&& [[prefs objectForKey:SPContentFilters] objectForKey:compareType])
	{
		[[contentFilters objectForKey:compareType] addObjectsFromArray:[[prefs objectForKey:SPContentFilters] objectForKey:compareType]];
	}

	// Load doc-based user-defined content filters
	if([[SPQueryController sharedQueryController] contentFilterForFileURL:[tableDocumentInstance fileURL]]) {
		id filters = [[SPQueryController sharedQueryController] contentFilterForFileURL:[tableDocumentInstance fileURL]];
		if([filters objectForKey:compareType])
			[[contentFilters objectForKey:compareType] addObjectsFromArray:[filters objectForKey:compareType]];
	}
#endif

	NSUInteger i = 0;
	if([contentFilters objectForKey:compareType]) {
		for (id filter in [contentFilters objectForKey:compareType]) {
			// Create the tooltip
			NSString *tooltip;
			if ([filter objectForKey:@"Tooltip"])
				tooltip = [filter objectForKey:@"Tooltip"];
			else {
				NSMutableString *tip = [[NSMutableString alloc] init];
				if ([filter objectForKey:@"Clause"] && [(NSString *) [filter objectForKey:@"Clause"] length]) {
					[tip setString:[[filter objectForKey:@"Clause"] stringByReplacingOccurrencesOfRegex:@"(?<!\\\\)(\\$\\{.*?\\})" withString:@"[arg]"]];
					if ([tip isMatchedByRegex:@"(?<!\\\\)\\$BINARY"]) {
						[tip replaceOccurrencesOfRegex:@"(?<!\\\\)\\$BINARY" withString:@""];
						[tip appendString:NSLocalizedString(@"\n\nPress ⇧ for binary search (case-sensitive).", @"\n\npress shift for binary search tooltip message")];
					}
					[tip flushCachedRegexData];
					[tip replaceOccurrencesOfRegex:@"(?<!\\\\)\\$CURRENT_FIELD" withString:[[colNode name] backtickQuotedString]];
					[tip flushCachedRegexData];
					tooltip = [NSString stringWithString:tip];
				} else {
					tooltip = @"";
				}
				[tip release];
			}

			OpNode *node = [[OpNode alloc] init];
			[node setParentColumn:colNode];
			[node setSettings:@{
				@"title": ([filter objectForKey:@"MenuLabel"] ? [filter objectForKey:@"MenuLabel"] : @"not specified"),
				@"tooltip": tooltip,
				@"tag": @(i),
				@"filterType": compareType,
			}];
			[node setFilter:filter];
			[compareItems addObject:node];
			[node release];
			i++;
		}
	}

	{
		OpNode *node = [[OpNode alloc] init];
		[node setParentColumn:colNode];
		[node setSettings:@{
			@"isSeparator": @YES,
		}];
		[compareItems addObject:node];
		[node release];
	}

	{
		OpNode *node = [[OpNode alloc] init];
		[node setParentColumn:colNode];
		[node setSettings:@{
			@"title": NSLocalizedString(@"Edit Filters…", @"edit filter"),
			@"tooltip": NSLocalizedString(@"Edit user-defined Filters…", @"edit user-defined filter"),
			@"tag": @(i),
			@"target": self,
			@"action": [NSValue valueWithPointer:@selector(_editFiltersAction:)],
			@"filterType": compareType,
		}];
		[compareItems addObject:node];
		[node release];
	}

	return compareItems;
}

- (IBAction)_editFiltersAction:(id)sender
{
	if([sender isKindOfClass:[NSMenuItem class]]) {
		NSMenuItem *menuItem = (NSMenuItem *)sender;
		NSString *filterType = [(NSDictionary *)[menuItem representedObject] objectForKey:@"filterType"];
		if([filterType unboxNull]) [self openContentFilterManagerForFilterType:filterType];
	}
}

- (void)openContentFilterManagerForFilterType:(NSString *)filterType
{
	// init query favorites controller
#ifndef SP_CODA
	[[NSUserDefaults standardUserDefaults] synchronize];
#endif
	if(contentFilterManager) [contentFilterManager release];
	contentFilterManager = [[SPContentFilterManager alloc] initWithDatabaseDocument:tableDocumentInstance forFilterType:filterType];

	// Open query favorite manager
	[NSApp beginSheet:[contentFilterManager window]
	   modalForWindow:[tableDocumentInstance parentWindow]
	    modalDelegate:contentFilterManager
	   didEndSelector:nil
	      contextInfo:nil];
}

- (void)_contentFiltersHaveBeenUpdated:(NSNotification *)notification
{
	//tell the rule editor to reload its criteria
	[filterRuleEditor reloadCriteria];
}

- (BOOL)isEmpty
{
	return ([[self model] count] == 0);
}

- (void)addFilterExpression
{
	[filterRuleEditor insertRowAtIndex:0 withType:NSRuleEditorRowTypeSimple asSubrowOfRow:-1 animate:NO];
}

- (NSString *)sqlWhereExpressionWithBinary:(BOOL)isBINARY error:(NSError **)err
{
	NSMutableString *filterString = [[NSMutableString alloc] init];
	NSError *innerError = nil;

	@autoreleasepool {
		//get the serialized filter and try to optimise it
		NSDictionary *filterTree = [[self class] _flattenSerializedFilter:[self _serializedFilterIncludingFilterDefinition:YES]];

		// build it recursively
		[[self class] _writeFilterTree:filterTree toString:filterString wrapInParenthesis:NO binary:isBINARY error:&innerError];

		[innerError retain]; // carry the error (if any) outside of the scope of the autoreleasepool
	}

	if(innerError) {
		[filterString release];
		if(err) *err = [innerError autorelease];
		return nil;
	}

	NSString *out = [filterString copy];
	[filterString release];

	return [out autorelease];
}

- (NSDictionary *)serializedFilter
{
	return [self _serializedFilterIncludingFilterDefinition:NO];
}

- (NSDictionary *)_serializedFilterIncludingFilterDefinition:(BOOL)includeDefinition
{
	NSMutableArray *rootItems = [NSMutableArray arrayWithCapacity:[model count]];
	for(NSDictionary *item in model) {
		[rootItems addObject:[self _serializeSubtree:item includingDefinition:includeDefinition]];
	}
	//the root serialized filter can either be an AND of multiple root items or a single root item
	if([rootItems count] == 1) {
		return [rootItems objectAtIndex:0];
	}
	else {
		return @{
			SerFilterClass: SerFilterClassGroup,
			SerFilterGroupIsConjunction: @YES,
			SerFilterGroupChildren: rootItems,
		};
	}
}

- (NSDictionary *)_serializeSubtree:(NSDictionary *)item includingDefinition:(BOOL)includeDefinition
{
	NSRuleEditorRowType rowType = (NSRuleEditorRowType)[[item objectForKey:@"rowType"] unsignedIntegerValue];
	// check if we have an AND or OR compound row
	if(rowType == NSRuleEditorRowTypeCompound) {
		// process all children
		NSArray *subrows = [item objectForKey:@"subrows"];
		NSMutableArray *children = [[NSMutableArray alloc] initWithCapacity:[subrows count]];
		for(NSDictionary *subitem in subrows) {
			[children addObject:[self _serializeSubtree:subitem includingDefinition:includeDefinition]];
		}
		StringNode *node = [[item objectForKey:@"criteria"] objectAtIndex:0];
		BOOL isConjunction = [@"AND" isEqualToString:[node value]];
		NSDictionary *out = @{
			SerFilterClass: SerFilterClassGroup,
			SerFilterGroupIsConjunction: @(isConjunction),
			SerFilterGroupChildren: children,
		};
		[children release];
		return out;
	}
	else {
		NSArray *criteria = [item objectForKey:@"criteria"];
		NSArray *displayValues = [item objectForKey:@"displayValues"];
		ColumnNode *col = [criteria objectAtIndex:0];
		OpNode *op = [criteria objectAtIndex:1];
		NSMutableArray *filterValues = [[NSMutableArray alloc] initWithCapacity:2];
		for (NSUInteger i = 2; i < [criteria count]; ++i) { // the first two must always be column and operator
			if([(RuleNode *)[criteria objectAtIndex:i] type] != RuleNodeTypeArgument) continue;
			// if we found an argument, the displayValue will be an NSTextField we can ask for the value
			NSString *value = [(NSTextField *)[displayValues objectAtIndex:i] stringValue];
			[filterValues addObject:value];
		}
		NSDictionary *out = @{
			SerFilterClass: SerFilterClassExpression,
			SerFilterExprColumn: [col name],
			SerFilterExprType: [[op settings] objectForKey:@"filterType"],
			SerFilterExprComparison: [[op filter] objectForKey:@"MenuLabel"],
			SerFilterExprValues: filterValues,
		};
		if(includeDefinition) {
			out = [NSMutableDictionary dictionaryWithDictionary:out];
			[(NSMutableDictionary *)out setObject:[op filter] forKey:SerFilterExprDefinition];
		}
		[filterValues release];
		return out;
	}
}

void _addIfNotNil(NSMutableArray *array, id toAdd)
{
	if(toAdd != nil) [array addObject:toAdd];
}

- (void)restoreSerializedFilters:(NSDictionary *)serialized
{
	if(!serialized) return;

	// we have to exchange the whole model object or NSRuleEditor will get confused
	NSMutableArray *newModel = [[NSMutableArray alloc] init];
	
	@autoreleasepool {
		// if the root object is an AND group directly restore its contents, otherwise restore the object
		if(SerIsGroup(serialized) && [[serialized objectForKey:SerFilterGroupIsConjunction] boolValue]) {
			for(NSDictionary *child in [serialized objectForKey:SerFilterGroupChildren]) {
				_addIfNotNil(newModel, [self _restoreSerializedFilter:child]);
			}
		}
		else {
			_addIfNotNil(newModel, [self _restoreSerializedFilter:serialized]);
		}
	}

	[self setModel:newModel];
	[newModel release];
}

- (NSMutableDictionary *)_restoreSerializedFilter:(NSDictionary *)serialized
{
	NSMutableDictionary *obj = [[NSMutableDictionary alloc] initWithCapacity:4];

	if(SerIsGroup(serialized)) {
		[obj setObject:@(NSRuleEditorRowTypeCompound) forKey:@"rowType"];

		StringNode *sn = [[StringNode alloc] init];
		[sn setValue:([[serialized objectForKey:SerFilterGroupIsConjunction] boolValue] ? @"AND" : @"OR")];
		// those have to be mutable arrays for the rule editor to work
		NSMutableArray *criteria = [NSMutableArray arrayWithObject:sn];
		[obj setObject:criteria forKey:@"criteria"];

		id displayValue = [self ruleEditor:filterRuleEditor displayValueForCriterion:sn inRow:-1];
		NSMutableArray *displayValues = [NSMutableArray arrayWithObject:displayValue];
		[obj setObject:displayValues forKey:@"displayValues"];
		[sn release];

		NSArray *children = [serialized objectForKey:SerFilterGroupChildren];
		NSMutableArray *subrows = [[NSMutableArray alloc] initWithCapacity:[children count]];
		for(NSDictionary *child in children) {
			_addIfNotNil(subrows, [self _restoreSerializedFilter:child]);
		}
		[obj setObject:subrows forKey:@"subrows"];
		[subrows release];
	}
	else {
		[obj setObject:@(NSRuleEditorRowTypeSimple) forKey:@"rowType"];
		//simple rows can't have child rows
		[obj setObject:[NSMutableArray array] forKey:@"subrows"];
		
		NSMutableArray *criteria = [NSMutableArray arrayWithCapacity:5];

		//first look up the column, bail if it doesn't exist anymore or types changed
		NSString *columnName = [serialized objectForKey:SerFilterExprColumn];
		ColumnNode *col = [self _columnForName:columnName];
		if(!col) {
			SPLog(@"cannot deserialize unknown column: %@", columnName);
			goto fail;
		}
		[criteria addObject:col];

		//next try to find the given operator
		NSString *operatorName = [serialized objectForKey:SerFilterExprComparison];
		OpNode *op = [self _operatorNamed:operatorName forColumn:col];
		if(!op) {
			SPLog(@"cannot deserialize unknown operator: %@",operatorName);
			goto fail;
		}
		[criteria addObject:op];

		// we still have to check if the current column type is the same as when we serialized because an operator
		// with the same name can still act differently for different types
		NSString *curFilterType = [[op settings] objectForKey:@"filterType"];
		NSString *serFilterType = [serialized objectForKey:SerFilterExprType]; // this is optional
		if(serFilterType && ![curFilterType isEqualToString:serFilterType]) {
			SPLog(@"mistmatch in filter types for operator %@: current=%@, serialized=%@",op,curFilterType,serFilterType);
			goto fail;
		}

		//now we have to create the argument node(s)
		NSInteger numOfArgs = [[[op filter] objectForKey:@"NumberOfArguments"] integerValue];
		//fail if the current op requires more arguments than we have stored values for
		NSArray *values = [serialized objectForKey:SerFilterExprValues];
		if(numOfArgs > [values count]) {
			SPLog(@"filter operator %@ requires %ld arguments, but only have %ld stored values!",op,numOfArgs,[values count]);
			goto fail;
		}
		
		// otherwise add them
		for (NSUInteger i = 0; i < numOfArgs; ++i) {
			// insert connector node between args?
			if(i > 0) {
				ConnectorNode *node = [[ConnectorNode alloc] init];
				[node setFilter:[op filter]];
				[node setLabelIndex:(i-1)]; // label 0 follows argument 0
				[criteria addObject:node];
				[node release];
			}
			ArgNode *arg = [[ArgNode alloc] init];
			[arg setArgIndex:i];
			[arg setFilter:[op filter]];
			[arg setInitialValue:[values objectAtIndex:i]];
			[criteria addObject:arg];
			[arg release];
		}
		
		[obj setObject:criteria forKey:@"criteria"];
		
		//the last thing that remains is creating the displayValues for all criteria
		NSMutableArray *displayValues = [NSMutableArray arrayWithCapacity:[criteria count]];
		for(id criterion in criteria) {
			id dispValue = [self ruleEditor:filterRuleEditor displayValueForCriterion:criterion inRow:-1];
			if(!dispValue) {
				SPLog(@"got nil displayValue for criterion %@ on deserialization!",criterion);
				goto fail;
			}
			[displayValues addObject:dispValue];
		}
		[obj setObject:displayValues forKey:@"displayValues"];
	}

	return [obj autorelease];

fail:
	[obj release];
	return nil;
}

- (NSDictionary *)makeSerializedFilterForColumn:(NSString *)colName operator:(NSString *)opName values:(NSArray *)values
{
	return @{
		SerFilterClass:          SerFilterClassExpression,
		SerFilterExprColumn:     colName,
		SerFilterExprComparison: opName,
		SerFilterExprValues:     values,
	};
}

- (ColumnNode *)_columnForName:(NSString *)name
{
	if([name length]) {
		for (ColumnNode *col in columns) {
			if ([name isEqualToString:[col name]]) return col;
		}
	}
	return nil;
}

- (OpNode *)_operatorNamed:(NSString *)title forColumn:(ColumnNode *)col
{
	if([title length]) {
		// check if we have the operator cache, otherwise build it
		if(![col operatorCache]) {
			NSArray *ops = [self _compareTypesForColumn:col];
			[col setOperatorCache:ops];
		}
		// try to find it in the operator cache
		for(OpNode *node in [col operatorCache]) {
			if([[[node filter] objectForKey:@"MenuLabel"] isEqualToString:title]) return node;
		}
	}
	return nil;
}

BOOL SerIsGroup(NSDictionary *dict)
{
	return [SerFilterClassGroup isEqual:[dict objectForKey:SerFilterClass]];
}

/**
 * This method looks at the given serialized filter in a recursive manner and
 * when it encounters
 * - a group node with only a single child or
 * - a child that is a group node of the same kind as the parent one
 * it will pull the child(ren) up
 *
 * So for example:
 *   AND(expr1)                  => expr1
 *   AND(expr1,AND(expr2,expr3)) => AND(expr1,expr2,expr3)
 *
 * The input dict is not modified, the returned dict will be equal to the input
 * dict or have parts of it removed or replaced with new dicts.
 */
+ (NSDictionary *)_flattenSerializedFilter:(NSDictionary *)in
{
	// return non-group-nodes as is
	if(!SerIsGroup(in)) return in;

	NSNumber *inIsConjunction = [in objectForKey:SerFilterGroupIsConjunction];

	// first give all children the chance to flatten (depth first)
	NSArray *children = [in objectForKey:SerFilterGroupChildren];
	NSMutableArray *flatChildren = [NSMutableArray arrayWithCapacity:[children count]];
	NSUInteger changed = 0;
	for(NSDictionary *child in children) {
		NSDictionary *flattened = [self _flattenSerializedFilter:child];
		//take a closer look at the (possibly changed) child - is it a group node of the same kind as us?
		if(SerIsGroup(flattened) && [inIsConjunction isEqual:[flattened objectForKey:SerFilterGroupIsConjunction]]) {
			[flatChildren addObjectsFromArray:[flattened objectForKey:SerFilterGroupChildren]];
			changed++;
		}
		else if(flattened != child) {
			changed++;
		}
		[flatChildren addObject:flattened];
	}
	// if there is only a single child, return it (flattening)
	if([flatChildren count] == 1) return [flatChildren objectAtIndex:0];
	// if none of the children changed return the original input
	if(!changed) return in;
	// last variant: some of our children changed, but we remain
	return @{
		SerFilterClass: SerFilterClassGroup,
		SerFilterGroupIsConjunction: inIsConjunction,
		SerFilterGroupChildren: flatChildren
	};
}

+ (void)_writeFilterTree:(NSDictionary *)in toString:(NSMutableString *)out wrapInParenthesis:(BOOL)wrap binary:(BOOL)isBINARY error:(NSError **)err
{
	NSError *myErr = nil;
	
	if(wrap) [out appendString:@"("];
	
	if(SerIsGroup(in)) {
		BOOL isConjunction = [[in objectForKey:SerFilterGroupIsConjunction] boolValue];
		NSString *connector = isConjunction ? @"AND" : @"OR";
		BOOL first = YES;
		NSArray *children = [in objectForKey:SerFilterGroupChildren];
		for(NSDictionary *child in children) {
			if(!first) [out appendFormat:@" %@ ",connector];
			else first = NO;
			// if the child is a group node but of a different kind we want to wrap it in order to prevent operator precedence confusion
			// expression children will always be wrapped for clarity, except if there is only a single one and we are already wrapped
			BOOL wrapChild = YES;
			if(SerIsGroup(child)) {
				BOOL childIsConjunction = [[child objectForKey:SerFilterGroupIsConjunction] boolValue];
				if(isConjunction == childIsConjunction) wrapChild = NO;
			}
			else {
				if(wrap && [children count] == 1) wrapChild = NO;
			}
			[self _writeFilterTree:child toString:out wrapInParenthesis:wrapChild binary:isBINARY error:&myErr];
			if(myErr) {
				if(err) *err = myErr;
				return;
			}
		}
	}
	else {
		// finally - build a SQL filter expression
		NSDictionary *filter = [in objectForKey:SerFilterExprDefinition];
		if(!filter) {
			if(err) *err = [NSError errorWithDomain:SPErrorDomain code:0 userInfo:@{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Fatal error while retrieving content filter. No filter definition found.", @"filter to sql conversion : internal error : 0"),
			}];
			return;
		}

		if(![filter objectForKey:@"NumberOfArguments"]) {
			if(err) *err = [NSError errorWithDomain:SPErrorDomain code:1 userInfo:@{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Error while retrieving filter clause. No “NumberOfArguments” key found.", @"filter to sql conversion : internal error : invalid filter definition (1)"),
			}];
			return;
		}

		if(![filter objectForKey:@"Clause"] || ![(NSString *)[filter objectForKey:@"Clause"] length]) {
			if(err) *err = [NSError errorWithDomain:SPErrorDomain code:2 userInfo:@{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Content Filter clause is empty.", @"filter to sql conversion : internal error : invalid filter definition (2)"),
			}];
			return;
		}

		NSArray *values = [in objectForKey:SerFilterExprValues];

		SPTableFilterParser *parser = [[SPTableFilterParser alloc] initWithFilterClause:[filter objectForKey:@"Clause"]
		                                                              numberOfArguments:[[filter objectForKey:@"NumberOfArguments"] integerValue]];
		[parser setArgument:[values objectOrNilAtIndex:0]];
		[parser setFirstBetweenArgument:[values objectOrNilAtIndex:0]];
		[parser setSecondBetweenArgument:[values objectOrNilAtIndex:1]];
		[parser setSuppressLeadingTablePlaceholder:[[filter objectForKey:@"SuppressLeadingFieldPlaceholder"] boolValue]];
		[parser setCaseSensitive:isBINARY];
		[parser setCurrentField:[in objectForKey:SerFilterExprColumn]];

		NSString *sql = [parser filterString];
		// SPTableFilterParser will return nil if it doesn't like the arguments and NSMutableString doesn't like nil
		if(!sql) {
			if(err) *err = [NSError errorWithDomain:SPErrorDomain code:3 userInfo:@{
				NSLocalizedDescriptionKey: NSLocalizedString(@"No valid SQL expression could be generated. Make sure that you have filled in all required fields.", @"filter to sql conversion : internal error : SPTableFilterParser failed"),
			}];
			[parser release];
			return;
		}
		[out appendString:sql];

		[parser release];
	}
	
	if(wrap) [out appendString:@")"];
}

@end

//TODO move
@interface SPFillView : NSView
{
	NSColor *currentColor;
}

/**
 * This method is invoked when unarchiving the View from the xib.
 * The value is configured in IB under "User Defined Runtime Attributes"
 */
- (void)setSystemColorOfName:(NSString *)name;

@end

@implementation SPFillView

- (void)setSystemColorOfName:(NSString *)name
{
	//TODO: xibs after 10.6 support storing colors as user defined attributes
	NSColorList *scl = [NSColorList colorListNamed:@"System"];
	NSColor *color = [scl colorWithKey:name];
	if(color) {
		[color retain];
		[currentColor release];
		currentColor = color;
		[self setNeedsDisplay:YES];
	}
}

- (void)drawRect:(NSRect)dirtyRect {
	if(currentColor) {
		[currentColor set];
		NSRectFill(dirtyRect);
	}
}

- (void)dealloc
{
	[currentColor release];
	[super dealloc];
}

@end
